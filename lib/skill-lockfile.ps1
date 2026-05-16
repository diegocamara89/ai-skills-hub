# lib/skill-lockfile.ps1 — skills.lock.json management
#
# Public functions:
#   Get-SkillLockfile [-Path]
#       Loads (or creates) the lockfile and returns it as a hashtable.
#       Schema: { version, updatedAt, skills: { <name>: { source, ref, commit,
#                sha256_tree, version, installedAt } } }
#
#   Add-SkillToLockfile -Name <n> -Source <s> -Ref <r> -Commit <c> -SkillDir <p>
#                       [-Version <v>] [-Path]
#       Computes sha256_tree, upserts entry, refreshes updatedAt, persists
#       atomically (Set-FileAtomic when manage-skills.ps1 is loaded; otherwise
#       a local atomic-write fallback is used so the lib stays self-contained).
#
#   Remove-SkillFromLockfile -Name <n> [-Path]
#       Removes the named entry, refreshes updatedAt, persists.
#
#   Get-SkillTreeHash -SkillDir <p>
#       Deterministic SHA-256 of every regular file inside the skill folder.
#       Algorithm:
#         1. Enumerate -Recurse -File, sort by RELATIVE path (lowercased,
#            forward-slash normalized) so order is stable across OS/locales.
#         2. For each file compute SHA-256 and emit a line "<relPath>:<sha>".
#         3. Final hash = SHA-256 of those lines joined by "`n".
#       Files inside .git, node_modules, __pycache__ are skipped.
#
# IMPORTANT: This file is dot-sourced from manage-skills.ps1 (Task 10/12).
# It must NOT execute side-effects on load. Pure function definitions only.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

$Script:SkillLockfileSchemaVersion = 1
$Script:SkillLockfileSkippedDirs   = @('.git', 'node_modules', '__pycache__', '.pytest_cache', '.venv')

function Get-SkillLockfileDefaultPath {
    # Repo root is one level above this lib/ folder.
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $repoRoot 'skills.lock.json')
}

function Get-NowUtcIso {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

function ConvertTo-LockfileHashtable {
    # Recursively turn PSCustomObject (from ConvertFrom-Json) into hashtable
    # so callers can safely mutate keys.
    param([Parameter(Mandatory)][AllowNull()]$InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in $InputObject.Keys) {
            $out[$k] = ConvertTo-LockfileHashtable -InputObject $InputObject[$k]
        }
        return $out
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $out[$p.Name] = ConvertTo-LockfileHashtable -InputObject $p.Value
        }
        return $out
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += ,(ConvertTo-LockfileHashtable -InputObject $item)
        }
        return ,$list
    }

    return $InputObject
}

function New-EmptySkillLockfile {
    return [ordered]@{
        version   = $Script:SkillLockfileSchemaVersion
        updatedAt = Get-NowUtcIso
        skills    = [ordered]@{}
    }
}

function Save-SkillLockfileInternal {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Lockfile
    )

    # Always normalize to ordered hashtable so JSON output stays stable.
    $normalized = ConvertTo-LockfileHashtable -InputObject $Lockfile
    if (-not $normalized.Contains('version'))   { $normalized['version']   = $Script:SkillLockfileSchemaVersion }
    if (-not $normalized.Contains('skills'))    { $normalized['skills']    = [ordered]@{} }
    $normalized['updatedAt'] = Get-NowUtcIso

    $json = $normalized | ConvertTo-Json -Depth 20
    # Validate round-trip before writing — catches malformed structures early.
    $null = $json | ConvertFrom-Json

    # Prefer Set-FileAtomic from manage-skills.ps1 when loaded for true
    # atomicity. Fall back to a local atomic-rename when running standalone
    # (e.g. from tests).
    if (Get-Command -Name Set-FileAtomic -ErrorAction SilentlyContinue) {
        Set-FileAtomic -Path $Path -Content $json -NoBom
        return
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $tmp = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        if (Test-Path -LiteralPath $Path) {
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        } else {
            Move-Item -LiteralPath $tmp -Destination $Path
        }
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

function Get-SkillLockfile {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if (-not $Path) { $Path = Get-SkillLockfileDefaultPath }

    if (-not (Test-Path -LiteralPath $Path)) {
        return New-EmptySkillLockfile
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return New-EmptySkillLockfile
    }

    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "skills.lock.json at '$Path' is corrupt: $($_.Exception.Message)"
    }

    $hash = ConvertTo-LockfileHashtable -InputObject $obj
    if (-not $hash.Contains('version'))   { $hash['version']   = $Script:SkillLockfileSchemaVersion }
    if (-not $hash.Contains('updatedAt')) { $hash['updatedAt'] = Get-NowUtcIso }
    if (-not $hash.Contains('skills') -or $null -eq $hash['skills']) {
        $hash['skills'] = [ordered]@{}
    }
    return $hash
}

function Get-SkillTreeHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SkillDir
    )

    if (-not (Test-Path -LiteralPath $SkillDir)) {
        throw "Skill directory not found: $SkillDir"
    }

    $rootItem = Get-Item -LiteralPath $SkillDir -Force
    $rootFull = $rootItem.FullName.TrimEnd('\','/')

    # Collect files, skipping noise dirs (.git etc.).
    $files = Get-ChildItem -LiteralPath $rootFull -Recurse -Force -File -ErrorAction Stop |
        Where-Object {
            $rel = $_.FullName.Substring($rootFull.Length).TrimStart('\','/')
            $segments = $rel -split '[\\/]+'
            -not ($segments | Where-Object { $Script:SkillLockfileSkippedDirs -contains $_ })
        }

    $entries = foreach ($file in $files) {
        $rel = $file.FullName.Substring($rootFull.Length).TrimStart('\','/')
        $relNormalized = ($rel -replace '\\', '/').ToLowerInvariant()
        $sha = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        [PSCustomObject]@{ Path = $relNormalized; Sha = $sha }
    }

    $sorted = $entries | Sort-Object -Property Path
    $joined = ($sorted | ForEach-Object { "$($_.Path):$($_.Sha)" }) -join "`n"

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
        $hashBytes = $sha256.ComputeHash($bytes)
        return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha256.Dispose()
    }
}

function Add-SkillToLockfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Ref,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$SkillDir,
        [string]$Version,
        [string]$Path
    )

    if (-not $Path) { $Path = Get-SkillLockfileDefaultPath }

    $treeHash = Get-SkillTreeHash -SkillDir $SkillDir

    $lockfile = Get-SkillLockfile -Path $Path
    $skills = $lockfile['skills']

    $existing = $null
    if ($skills.Contains($Name)) {
        $existing = $skills[$Name]
    }

    # Preserve installedAt across updates so the field reflects the original
    # install time; only refresh when the entry is brand-new.
    $installedAt = if ($existing -and $existing.Contains('installedAt') -and $existing['installedAt']) {
        $existing['installedAt']
    } else {
        Get-NowUtcIso
    }

    $entry = [ordered]@{
        source       = $Source
        ref          = $Ref
        commit       = $Commit
        sha256_tree  = $treeHash
        version      = if ($Version) { $Version } else { $null }
        installedAt  = $installedAt
    }

    $skills[$Name] = $entry
    $lockfile['skills'] = $skills

    Save-SkillLockfileInternal -Path $Path -Lockfile $lockfile

    return $lockfile
}

function Remove-SkillFromLockfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path
    )

    if (-not $Path) { $Path = Get-SkillLockfileDefaultPath }

    $lockfile = Get-SkillLockfile -Path $Path
    $skills = $lockfile['skills']

    if ($skills.Contains($Name)) {
        $skills.Remove($Name) | Out-Null
        $lockfile['skills'] = $skills
        Save-SkillLockfileInternal -Path $Path -Lockfile $lockfile
    } else {
        # Still bump updatedAt to reflect the no-op call? Spec says only
        # "removes entry" — keep file untouched if name not present.
    }

    return $lockfile
}
