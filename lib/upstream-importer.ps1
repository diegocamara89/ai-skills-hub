# lib/upstream-importer.ps1 — Task 10
#
# Adapters for known upstream skill catalogs:
#   ccpi       -> jeremylongshore/claude-code-plugins   (skills/<name>/)
#   ccpm       -> daymade/claude-code-skills            (skills/<name>/)
#   alireza    -> alirezarezvani/claude-skills          (skills/<name>/)
#   anthropics -> anthropics/skills                     (<name>/  flat at root)
#   generic    -> any other URL                         (<name>/SKILL.md at root)
#
# Public functions:
#   Resolve-UpstreamSource -Url <url>
#       Returns the source token ('ccpi'|'ccpm'|'alireza'|'anthropics'|'generic').
#
#   Import-FromUpstream -Url <url> [-SkillName <subpath>] [-Target <path>]
#                       [-Branch <ref>] [-LockfilePath <p>] [-AllSkillsRoot <p>]
#                       [-TempRoot <p>] [-GitExecutable <p>]
#       Performs a shallow clone, applies the source-specific layout adapter,
#       validates frontmatter, registers the skill in the lockfile, drops a
#       .skill-meta.json sidecar, and returns a structured result hashtable.
#
# IMPORTANT: This file is dot-sourced. No load-time side-effects. The script
# delegates atomic file writes to Set-FileAtomic when available
# (manage-skills.ps1 dot-sources both libs), and falls back to a local
# atomic-write helper when used standalone (e.g. from tests).
#
# Dependencies (resolved at call time, not load time):
#   - Test-SkillFrontmatter   from lib/frontmatter-validator.ps1
#   - Add-SkillToLockfile     from lib/skill-lockfile.ps1
#   - Set-FileAtomic          from manage-skills.ps1 (optional, fallback used otherwise)
#   - Write-StructuredLog     from aiox-shared/StructuredLogger.psm1 (optional)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function _UpstreamImporter_NowIso {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
}

function _UpstreamImporter_DefaultTempRoot {
    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath("UserProfile") }
    return (Join-Path $userProfile ".claude-orchestrator\tmp")
}

function _UpstreamImporter_DefaultAllSkillsRoot {
    if ($Script:AllSkillsRoot) { return $Script:AllSkillsRoot }
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $repoRoot 'all-skills')
}

function _UpstreamImporter_WriteJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data,
        [int]$Depth = 10
    )
    $json = $Data | ConvertTo-Json -Depth $Depth
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

function _UpstreamImporter_TryLog {
    param(
        [Parameter(Mandatory)][string]$Event,
        [string]$Level = 'info',
        [hashtable]$Properties = @{}
    )
    if (-not (Get-Command -Name Write-StructuredLog -ErrorAction SilentlyContinue)) { return }

    $userProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath("UserProfile") }
    $logFile = Join-Path $userProfile ".claude-orchestrator\usage\logs\skill-imports.jsonl"
    try {
        Write-StructuredLog -Path $logFile -Event $Event -Level $Level -Properties $Properties
    } catch {
        # Logging must never break the importer.
    }
}

function _UpstreamImporter_RunGit {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function _UpstreamImporter_DeriveRepoName {
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -match 'github\.com[/:]([^/]+)/([^/.\s]+)(?:\.git)?(?:[/?#]|$)') {
        return $Matches[2]
    }
    # Last path segment
    $stripped = $Url.TrimEnd('/').TrimEnd('.git')
    $segments = $stripped -split '[/\\]'
    return $segments[-1]
}

# Best-effort guess of a sensible default skill name when caller passes none.
function _UpstreamImporter_DefaultSkillName {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Url
    )
    return (_UpstreamImporter_DeriveRepoName -Url $Url)
}

# ---------------------------------------------------------------------------
# Public API: source detection
# ---------------------------------------------------------------------------

function Resolve-UpstreamSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return 'generic' }

    # Order matters: more-specific patterns first.
    if ($Url -imatch 'jeremylongshore/claude-code-plugins') { return 'ccpi' }
    if ($Url -imatch 'daymade/claude-code-skills')          { return 'ccpm' }
    if ($Url -imatch 'alirezarezvani/claude-skills')        { return 'alireza' }
    if ($Url -imatch 'anthropics/skills')                   { return 'anthropics' }
    return 'generic'
}

# ---------------------------------------------------------------------------
# Adapter resolver — given a clone path + source token, returns the
# absolute path to the directory that should be copied into all-skills.
# Returns $null when the requested skill cannot be located.
# ---------------------------------------------------------------------------

function _UpstreamImporter_ResolveSourceLayout {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$ClonePath,
        [Parameter(Mandatory)][string]$SkillName
    )

    switch ($Source) {
        'ccpi'       { return (Join-Path $ClonePath ("skills\" + $SkillName)) }
        'ccpm'       { return (Join-Path $ClonePath ("skills\" + $SkillName)) }
        'alireza'    { return (Join-Path $ClonePath ("skills\" + $SkillName)) }
        'anthropics' { return (Join-Path $ClonePath $SkillName) }
        default      { return (Join-Path $ClonePath $SkillName) }
    }
}

# ---------------------------------------------------------------------------
# Public API: import
# ---------------------------------------------------------------------------

function Import-FromUpstream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$SkillName,
        [string]$Target,
        [string]$Branch = 'main',
        [string]$LockfilePath,
        [string]$AllSkillsRoot,
        [string]$TempRoot,
        [string]$GitExecutable = 'git'
    )

    if (-not $AllSkillsRoot) { $AllSkillsRoot = _UpstreamImporter_DefaultAllSkillsRoot }
    if (-not $TempRoot)      { $TempRoot      = _UpstreamImporter_DefaultTempRoot }

    $source = Resolve-UpstreamSource -Url $Url
    if (-not $SkillName) {
        $SkillName = _UpstreamImporter_DefaultSkillName -Source $source -Url $Url
    }

    if ([string]::IsNullOrWhiteSpace($SkillName)) {
        throw "Could not determine SkillName for URL '$Url'."
    }

    if (-not $Target) { $Target = Join-Path $AllSkillsRoot $SkillName }

    if (Test-Path -LiteralPath $Target) {
        throw "Target already exists: $Target"
    }

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $tmpPath = Join-Path $TempRoot ("upstream-{0}-{1}-{2}" -f $source, $timestamp, ([guid]::NewGuid().ToString('N').Substring(0,6)))

    if (-not (Test-Path -LiteralPath $TempRoot)) {
        New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    }

    $clonedCommit = $null

    try {
        _UpstreamImporter_TryLog -Event 'upstream-import-start' -Properties @{
            url = $Url; source = $source; skillName = $SkillName; target = $Target
        }

        # 1) Shallow clone -----------------------------------------------------
        $cloneArgs = @('clone', '--depth', '1', '--branch', $Branch, $Url, $tmpPath)
        $cloneResult = _UpstreamImporter_RunGit -Executable $GitExecutable -Arguments $cloneArgs

        # Some test mocks return $null exit (no real process). Treat null as 0.
        $exit = if ($null -eq $cloneResult.ExitCode) { 0 } else { [int]$cloneResult.ExitCode }
        if ($exit -ne 0) {
            $stderr = if ($cloneResult.StdErr) { $cloneResult.StdErr.Trim() } else { '' }
            throw "git clone failed (exit $exit): $stderr"
        }

        if (-not (Test-Path -LiteralPath $tmpPath)) {
            throw "Clone reported success but '$tmpPath' is missing."
        }

        # 2) Resolve the skill source folder via adapter -----------------------
        $sourceDir = _UpstreamImporter_ResolveSourceLayout -Source $source -ClonePath $tmpPath -SkillName $SkillName
        if (-not (Test-Path -LiteralPath $sourceDir)) {
            throw "Skill folder not found in clone: '$sourceDir' (source=$source, name=$SkillName)"
        }

        $skillMd = Join-Path $sourceDir 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillMd)) {
            throw "SKILL.md missing in source folder: $sourceDir"
        }

        # 3) Capture commit SHA ------------------------------------------------
        $revResult = _UpstreamImporter_RunGit -Executable $GitExecutable -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $tmpPath
        $revExit = if ($null -eq $revResult.ExitCode) { 0 } else { [int]$revResult.ExitCode }
        if ($revExit -eq 0 -and $revResult.StdOut) {
            $clonedCommit = $revResult.StdOut.Trim()
        }
        if (-not $clonedCommit) { $clonedCommit = 'unknown' }

        # 4) Copy into the catalog --------------------------------------------
        $targetParent = Split-Path -Parent $Target
        if ($targetParent -and -not (Test-Path -LiteralPath $targetParent)) {
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        }

        if (Get-Command -Name Copy-SkillTree -ErrorAction SilentlyContinue) {
            Copy-SkillTree -SourcePath $sourceDir -DestinationPath $Target -BackupLabel "upstream-$source-$SkillName"
        } else {
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
            $robocopy = Get-Command -Name robocopy -ErrorAction SilentlyContinue
            if ($robocopy) {
                & robocopy $sourceDir $Target /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -gt 7) {
                    throw "robocopy failed copying $sourceDir to $Target (exit $LASTEXITCODE)"
                }
            } else {
                Copy-Item -LiteralPath (Join-Path $sourceDir '*') -Destination $Target -Recurse -Force
            }
        }

        if (-not (Test-Path -LiteralPath (Join-Path $Target 'SKILL.md'))) {
            throw "SKILL.md missing in target after copy: $Target"
        }

        # 5) Validate frontmatter (optional dependency) ------------------------
        if (Get-Command -Name Test-SkillFrontmatter -ErrorAction SilentlyContinue) {
            $validation = Test-SkillFrontmatter -SkillDir $Target
            if (-not $validation.valid) {
                $reasons = @()
                foreach ($e in $validation.errors) {
                    if ($e.severity -eq 'error') {
                        $reasons += "$($e.field): $($e.reason)"
                    }
                }
                $reasonStr = ($reasons -join '; ')
                # Roll back: delete the imported folder so the catalog stays clean.
                Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
                _UpstreamImporter_TryLog -Event 'upstream-import-invalid-frontmatter' -Level 'error' -Properties @{
                    url = $Url; source = $source; skillName = $SkillName; reasons = $reasonStr
                }
                throw "Frontmatter validation failed for '$SkillName': $reasonStr"
            }
        }

        # 6) Add to lockfile (optional dependency) -----------------------------
        $lockfileUpdated = $false
        if (Get-Command -Name Add-SkillToLockfile -ErrorAction SilentlyContinue) {
            $addArgs = @{
                Name     = $SkillName
                Source   = $source
                Ref      = $Branch
                Commit   = $clonedCommit
                SkillDir = $Target
            }
            if ($LockfilePath) { $addArgs['Path'] = $LockfilePath }
            Add-SkillToLockfile @addArgs | Out-Null
            $lockfileUpdated = $true
        }

        # 7) Drop .skill-meta.json sidecar -------------------------------------
        $metaPath = Join-Path $Target '.skill-meta.json'
        $meta = [ordered]@{
            source      = $source
            importedAt  = _UpstreamImporter_NowIso
            originalUrl = $Url
            skillName   = $SkillName
            ref         = $Branch
            commit      = $clonedCommit
        }
        _UpstreamImporter_WriteJsonAtomic -Path $metaPath -Data $meta -Depth 10

        _UpstreamImporter_TryLog -Event 'upstream-import-success' -Properties @{
            url = $Url; source = $source; skillName = $SkillName; commit = $clonedCommit
        }

        return [pscustomobject]@{
            success         = $true
            source          = $source
            skillName       = $SkillName
            target          = $Target
            commit          = $clonedCommit
            ref             = $Branch
            metaPath        = $metaPath
            lockfileUpdated = $lockfileUpdated
            originalUrl     = $Url
        }
    } catch {
        $errMsg = $_.Exception.Message
        _UpstreamImporter_TryLog -Event 'upstream-import-failed' -Level 'error' -Properties @{
            url = $Url; source = $source; skillName = $SkillName; reason = $errMsg
        }
        throw
    } finally {
        # Always clean the temp clone, even on failure.
        if (Test-Path -LiteralPath $tmpPath) {
            try {
                Remove-Item -LiteralPath $tmpPath -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                # last-resort cleanup: nothing else we can do
            }
        }
    }
}
