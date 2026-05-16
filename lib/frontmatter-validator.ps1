# lib/frontmatter-validator.ps1
# Robust SKILL.md frontmatter validator (Task 11 — port of ccpm).
# Public surface:
#   Test-SkillFrontmatter -SkillDir <path>
#       Returns hashtable with @{ valid; errors=@(@{severity;field;reason}); parsed=@{...} }
#
# Severity policy:
#   error  -> structural problems that make the skill unusable
#            (missing SKILL.md, missing frontmatter, missing required field,
#             malformed kebab-case name, oversize fields, missing referenced file)
#   warn   -> cosmetic / soft issues that do not block loading
#            (BOM present, trailing whitespace on frontmatter line, invalid semver)
#
# `valid` is $true iff there is no entry with severity='error'.
#
# Optional helper Write-StructuredLog is consumed if the caller imported it,
# but this file does not depend on it directly to keep the validator pure.

# ----- private helpers -----

function _New-FrontmatterError {
    param(
        [Parameter(Mandatory)][ValidateSet('error', 'warn')][string]$Severity,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][string]$Reason
    )
    return @{
        severity = $Severity
        field    = $Field
        reason   = $Reason
    }
}

function _Parse-FrontmatterBlock {
    # Returns @{ frontmatter=<string|null>; body=<string>; hadBom=<bool>; rawLines=<string[]> }
    param([Parameter(Mandatory)][string]$Raw)

    $hadBom = $false
    if ($Raw.Length -gt 0 -and $Raw[0] -eq [char]0xFEFF) {
        $hadBom = $true
        $Raw = $Raw.Substring(1)
    }

    $frontmatter = $null
    $body = $Raw
    $rawLines = @()

    # Match leading frontmatter block delimited by --- on its own line.
    if ($Raw -match "(?s)\A---\s*\r?\n(.*?)\r?\n---\s*\r?\n?(.*)$") {
        $frontmatter = $Matches[1]
        $body = $Matches[2]
        $rawLines = $frontmatter -split "\r?\n"
    }

    return @{
        frontmatter = $frontmatter
        body        = $body
        hadBom      = $hadBom
        rawLines    = $rawLines
    }
}

function _Parse-FrontmatterFields {
    # Very small YAML subset parser: scalar key:value pairs only.
    # Multi-line / nested structures are returned as raw strings, validators
    # below treat anything non-scalar as invalid for the fields they care about.
    param([Parameter(Mandatory)][string]$Frontmatter)

    $result = [ordered]@{}
    foreach ($line in ($Frontmatter -split "\r?\n")) {
        if ($line -match '^\s*#') { continue }                         # comment
        if ($line.Trim() -eq '') { continue }                          # blank
        if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$') { continue }

        $key = $Matches[1]
        $val = $Matches[2]

        # Strip surrounding quotes (single or double).
        $valTrim = $val.Trim()
        if ($valTrim.Length -ge 2) {
            if (($valTrim.StartsWith('"') -and $valTrim.EndsWith('"')) -or
                ($valTrim.StartsWith("'") -and $valTrim.EndsWith("'"))) {
                $valTrim = $valTrim.Substring(1, $valTrim.Length - 2)
            }
        }
        $result[$key] = $valTrim
    }
    return $result
}

function _Find-ReferencedFiles {
    # Returns unique relative paths of the form references/<something>
    # found anywhere in $Body or $Frontmatter (e.g. 'references/api.md',
    # 'references/foo/bar.txt'). Markdown links and bare references are both
    # captured.
    param(
        [string]$Body,
        [string]$Frontmatter
    )

    $haystack = "$Frontmatter`n$Body"
    $found = New-Object System.Collections.Generic.HashSet[string]

    # Pattern: 'references/' followed by a path segment until whitespace,
    # quote, paren, bracket, or end-of-line.
    $regex = [regex]'references/[^\s"''()<>\]\[`]+'
    foreach ($m in $regex.Matches($haystack)) {
        $val = $m.Value.TrimEnd('.', ',', ';', ':', '`')
        # Reject obvious URL fragments / globs.
        if ($val -match '[\*\?]') { continue }
        [void]$found.Add($val)
    }
    return @($found)
}

# ----- public entry point -----

function Test-SkillFrontmatter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SkillDir
    )

    $errors = New-Object System.Collections.Generic.List[hashtable]
    $parsed = $null

    # 1) SKILL.md exists -----------------------------------------------------
    $skillFile = Join-Path $SkillDir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillFile)) {
        $errors.Add((_New-FrontmatterError -Severity 'error' -Field 'SKILL.md' `
            -Reason "SKILL.md not found in $SkillDir"))
        return @{
            valid  = $false
            errors = @($errors)
            parsed = $null
        }
    }

    # 2) Read raw content (preserve BOM detection) ---------------------------
    # Read bytes ourselves so we can detect the UTF-8 BOM reliably across
    # PowerShell editions (PS7's Get-Content -Encoding UTF8 silently strips it).
    $bytes = [System.IO.File]::ReadAllBytes($skillFile)
    $hadBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hadBom) {
        $raw = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    else {
        $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    if ($null -eq $raw) { $raw = '' }

    $parsedBlock = _Parse-FrontmatterBlock -Raw $raw

    if ($hadBom) {
        $errors.Add((_New-FrontmatterError -Severity 'warn' -Field 'SKILL.md' `
            -Reason 'File starts with UTF-8 BOM (0xFEFF) — should be UTF-8 without BOM'))
    }

    # 3) Frontmatter block must be present ----------------------------------
    if ($null -eq $parsedBlock.frontmatter) {
        $errors.Add((_New-FrontmatterError -Severity 'error' -Field 'frontmatter' `
            -Reason "Missing YAML frontmatter delimited by '---' lines at start of file"))
        return @{
            valid  = $false
            errors = @($errors)
            parsed = $null
        }
    }

    # 4) Trailing whitespace check (warn) -----------------------------------
    foreach ($line in $parsedBlock.rawLines) {
        if ($line -match '[ \t]+$') {
            $errors.Add((_New-FrontmatterError -Severity 'warn' -Field 'frontmatter' `
                -Reason "Trailing whitespace on frontmatter line: '$($line.TrimEnd())'"))
            break  # one warn is enough
        }
    }

    $fields = _Parse-FrontmatterFields -Frontmatter $parsedBlock.frontmatter

    # 5) name -----------------------------------------------------------------
    if (-not $fields.Contains('name') -or [string]::IsNullOrWhiteSpace($fields['name'])) {
        $errors.Add((_New-FrontmatterError -Severity 'error' -Field 'name' `
            -Reason 'name is required and must be a non-empty string'))
    }
    else {
        $name = [string]$fields['name']
        if ($name.Length -gt 64) {
            $errors.Add((_New-FrontmatterError -Severity 'error' -Field 'name' `
                -Reason "name must be <= 64 chars (was $($name.Length))"))
        }
        # kebab-case: starts with letter, lowercase, hyphen-separated segments
        # only. Use case-sensitive match via -cmatch since PowerShell -match
        # is case-insensitive by default.
        if ($name -cnotmatch '^[a-z][a-z0-9]*(-[a-z0-9]+)*$') {
            $errors.Add((_New-FrontmatterError -Severity 'error' -Field 'name' `
                -Reason "name must be kebab-case ([a-z][a-z0-9]*(-[a-z0-9]+)*), got '$name'"))
        }
    }

    # 6) description ---------------------------------------------------------
    if (-not $fields.Contains('description') -or [string]::IsNullOrWhiteSpace($fields['description'])) {
        $errors.Add((_New-FrontmatterError -Severity 'error' -Field 'description' `
            -Reason 'description is required and must be a non-empty string'))
    }
    else {
        $desc = [string]$fields['description']
        if ($desc.Length -gt 1024) {
            $errors.Add((_New-FrontmatterError -Severity 'error' -Field 'description' `
                -Reason "description must be <= 1024 chars (was $($desc.Length))"))
        }
    }

    # 7) version (optional) --------------------------------------------------
    if ($fields.Contains('version') -and -not [string]::IsNullOrWhiteSpace($fields['version'])) {
        $version = [string]$fields['version']
        # Accept full SemVer 2.0 (with optional pre-release / build metadata).
        $semver = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
        if ($version -notmatch $semver) {
            $errors.Add((_New-FrontmatterError -Severity 'warn' -Field 'version' `
                -Reason "version '$version' is not valid SemVer (MAJOR.MINOR.PATCH[-pre][+build])"))
        }
    }

    # 8) referenced files ----------------------------------------------------
    $refs = _Find-ReferencedFiles -Body $parsedBlock.body -Frontmatter $parsedBlock.frontmatter
    foreach ($ref in $refs) {
        $abs = Join-Path $SkillDir $ref
        if (-not (Test-Path -LiteralPath $abs)) {
            $errors.Add((_New-FrontmatterError -Severity 'error' -Field "references" `
                -Reason "Referenced file not found: $ref"))
        }
    }

    # Compose parsed output (best-effort even if some warns/errors fired).
    $parsed = @{
        name        = if ($fields.Contains('name')) { [string]$fields['name'] } else { $null }
        description = if ($fields.Contains('description')) { [string]$fields['description'] } else { $null }
    }
    foreach ($k in $fields.Keys) {
        if ($k -ne 'name' -and $k -ne 'description') {
            $parsed[$k] = $fields[$k]
        }
    }

    $hasError = ($errors | Where-Object { $_.severity -eq 'error' }).Count -gt 0
    return @{
        valid  = (-not $hasError)
        errors = @($errors)
        parsed = $parsed
    }
}
