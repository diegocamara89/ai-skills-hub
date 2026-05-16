# aiox-shared/Cleanup.psm1 -- Rotation and cleanup of auth sessions and JSONL logs
#
# Responsibilities:
#   1) Archive old claude-auth/* session folders into monthly zips (state\claude-auth-archive\YYYY-MM.zip)
#      and delete the originals ONLY after the zip is confirmed present on disk.
#   2) Truncate JSONL logs in ~/.claude-orchestrator/usage/logs/ that exceed -LogMaxSizeMB,
#      keeping only the last ~$LogTruncateToMB MB (aligned to a newline) and rolling the
#      removed prefix into a monthly archive zip.
#   3) Emit structured log entries to ~/.claude-orchestrator/usage/logs/cleanup.jsonl.
#
# Design notes:
#   - DryRun MUST never touch disk (no zip, no delete, no truncate, no .bak).
#   - All bytes-freed accounting is tracked even in DryRun (so it reflects what would happen).
#   - Per-target failures (zip threw, file locked) become 'cleanup-error' entries; they do
#     NOT abort the overall run. Aggregate result still returns.

Set-StrictMode -Version Latest

$Script:HubRoot      = 'C:\Users\marce\Diego\AI-Skills-Hub'
$Script:AuthRoot     = Join-Path $Script:HubRoot 'state\claude-auth'
$Script:AuthArchive  = Join-Path $Script:HubRoot 'state\claude-auth-archive'
$Script:LogsRoot     = Join-Path $env:USERPROFILE '.claude-orchestrator\usage\logs'
$Script:CleanupLog   = Join-Path $Script:LogsRoot 'cleanup.jsonl'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-CleanupLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Event,
        [hashtable]$Properties = @{},
        [string]$Path = $Script:CleanupLog
    )
    $entry = [ordered]@{
        ts    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        level = 'info'
        event = $Event
    }
    foreach ($k in $Properties.Keys) { $entry[$k] = $Properties[$k] }
    $json = $entry | ConvertTo-Json -Compress -Depth 5
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Get-DirectorySizeBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0L }
    try {
        $sum = 0L
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $sum += [int64]$_.Length }
        return $sum
    } catch {
        return 0L
    }
}

function Add-FolderToZip {
    # Adds the contents of $SourceFolder under prefix <leaf>/ inside $ZipPath.
    # Creates the zip if missing, otherwise APPENDS.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$ZipPath
    )
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $parent = Split-Path -Parent $ZipPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $mode = if (Test-Path -LiteralPath $ZipPath) {
        [System.IO.Compression.ZipArchiveMode]::Update
    } else {
        [System.IO.Compression.ZipArchiveMode]::Create
    }

    $fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, $mode)
        try {
            $leaf = Split-Path -Leaf $SourceFolder
            $files = Get-ChildItem -LiteralPath $SourceFolder -Recurse -File -Force -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($SourceFolder.Length).TrimStart('\','/')
                $entryName = "$leaf/$rel" -replace '\\','/'
                # If updating and entry already exists, give it a unique suffix to avoid collision.
                if ($mode -eq [System.IO.Compression.ZipArchiveMode]::Update) {
                    $existing = $zip.GetEntry($entryName)
                    if ($existing) {
                        $stamp = (Get-Date).ToString('yyyyMMddHHmmssfff')
                        $entryName = "$leaf-$stamp/$rel" -replace '\\','/'
                    }
                }
                $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                try {
                    $src = [System.IO.File]::OpenRead($f.FullName)
                    try { $src.CopyTo($entryStream) } finally { $src.Dispose() }
                } finally {
                    $entryStream.Dispose()
                }
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $fs.Dispose()
    }
}

function Add-FileToArchiveZip {
    # Adds $SourceFile into $ZipPath under the file's leaf name (timestamp-suffixed
    # if a collision occurs in Update mode).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$ZipPath
    )
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $parent = Split-Path -Parent $ZipPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $mode = if (Test-Path -LiteralPath $ZipPath) {
        [System.IO.Compression.ZipArchiveMode]::Update
    } else {
        [System.IO.Compression.ZipArchiveMode]::Create
    }

    $fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($fs, $mode)
        try {
            $entryName = Split-Path -Leaf $SourceFile
            if ($mode -eq [System.IO.Compression.ZipArchiveMode]::Update -and $zip.GetEntry($entryName)) {
                $stamp = (Get-Date).ToString('yyyyMMddHHmmssfff')
                $entryName = "$entryName.$stamp"
            }
            $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $src = [System.IO.File]::OpenRead($SourceFile)
                try { $src.CopyTo($entryStream) } finally { $src.Dispose() }
            } finally {
                $entryStream.Dispose()
            }
        } finally {
            $zip.Dispose()
        }
    } finally {
        $fs.Dispose()
    }
}

function Invoke-JsonlTailTruncate {
    # Rewrites $Path to contain only the last $KeepBytes bytes, aligned to a newline
    # (drops the partial leading line). Returns the actual number of bytes kept.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$KeepBytes
    )

    $fi = Get-Item -LiteralPath $Path -Force
    $total = [int64]$fi.Length
    if ($KeepBytes -ge $total) { return $total }

    # Read the tail into a byte buffer.
    $startOffset = $total - $KeepBytes
    $tail = New-Object byte[] $KeepBytes
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        [void]$fs.Seek($startOffset, [System.IO.SeekOrigin]::Begin)
        $read = $fs.Read($tail, 0, $KeepBytes)
        if ($read -lt $KeepBytes) {
            $resized = New-Object byte[] $read
            [Array]::Copy($tail, $resized, $read)
            $tail = $resized
        }
    } finally {
        $fs.Dispose()
    }

    # Align to next \n boundary so we don't keep a half-line at the top.
    $nl = [byte]([char]"`n")
    $align = 0
    for ($i = 0; $i -lt $tail.Length; $i++) {
        if ($tail[$i] -eq $nl) { $align = $i + 1; break }
    }
    if ($align -gt 0 -and $align -lt $tail.Length) {
        $kept = New-Object byte[] ($tail.Length - $align)
        [Array]::Copy($tail, $align, $kept, 0, $kept.Length)
        $tail = $kept
    }

    # Overwrite the file with the aligned tail.
    [System.IO.File]::WriteAllBytes($Path, $tail)
    return [int64]$tail.Length
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

function Invoke-AioxCleanup {
    [CmdletBinding()]
    param(
        [int]$SessionDaysToKeep = 14,
        [int]$LogMaxSizeMB      = 50,
        [int]$LogTruncateToMB   = 25,
        [switch]$DryRun,

        # Test hooks (allow tests to redirect to TestDrive without touching real disk).
        [string]$AuthRootOverride,
        [string]$AuthArchiveOverride,
        [string]$LogsRootOverride,
        [string]$CleanupLogOverride
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $authRoot    = if ($AuthRootOverride)    { $AuthRootOverride }    else { $Script:AuthRoot }
    $authArchive = if ($AuthArchiveOverride) { $AuthArchiveOverride } else { $Script:AuthArchive }
    $logsRoot    = if ($LogsRootOverride)    { $LogsRootOverride }    else { $Script:LogsRoot }
    $cleanupLog  = if ($CleanupLogOverride)  { $CleanupLogOverride }  else { $Script:CleanupLog }

    $result = [ordered]@{
        sessionsArchived = 0
        sessionsRemoved  = 0
        logsRotated      = 0
        bytesFreed       = 0L
        durationMs       = 0
        dryRun           = [bool]$DryRun
    }

    $cutoff = (Get-Date).AddDays(-$SessionDaysToKeep)

    # --- 1) Session archiving --------------------------------------------------
    if (Test-Path -LiteralPath $authRoot) {
        $oldFolders = Get-ChildItem -LiteralPath $authRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff }

        # Group by YYYY-MM bucket (based on LastWriteTime).
        $grouped = $oldFolders | Group-Object { $_.LastWriteTime.ToString('yyyy-MM') }

        foreach ($bucket in $grouped) {
            $zipPath = Join-Path $authArchive ("$($bucket.Name).zip")
            foreach ($folder in $bucket.Group) {
                $sizeBytes = Get-DirectorySizeBytes -Path $folder.FullName
                if ($DryRun) {
                    $result.sessionsArchived++
                    $result.sessionsRemoved++
                    $result.bytesFreed += [int64]$sizeBytes
                    continue
                }

                try {
                    Add-FolderToZip -SourceFolder $folder.FullName -ZipPath $zipPath
                } catch {
                    Write-CleanupLog -Path $cleanupLog -Event 'cleanup-error' -Properties @{
                        target = $folder.FullName
                        action = 'zip-session'
                        reason = $_.Exception.Message
                    }
                    continue
                }

                if (-not (Test-Path -LiteralPath $zipPath)) {
                    Write-CleanupLog -Path $cleanupLog -Event 'cleanup-error' -Properties @{
                        target = $folder.FullName
                        action = 'zip-session'
                        reason = 'zip-not-found-after-write'
                    }
                    continue
                }

                try {
                    Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction Stop
                    $result.sessionsArchived++
                    $result.sessionsRemoved++
                    $result.bytesFreed += [int64]$sizeBytes
                } catch {
                    Write-CleanupLog -Path $cleanupLog -Event 'cleanup-error' -Properties @{
                        target = $folder.FullName
                        action = 'remove-session'
                        reason = $_.Exception.Message
                    }
                }
            }
        }
    }

    # --- 2) JSONL log truncation ----------------------------------------------
    if (Test-Path -LiteralPath $logsRoot) {
        $logFiles = Get-ChildItem -LiteralPath $logsRoot -Filter '*.jsonl' -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne (Split-Path -Leaf $cleanupLog) }

        $maxBytes  = [int64]$LogMaxSizeMB     * 1024L * 1024L
        $keepBytes = [int64]$LogTruncateToMB  * 1024L * 1024L

        foreach ($lf in $logFiles) {
            if ($lf.Length -le $maxBytes) { continue }

            $beforeLen = [int64]$lf.Length

            if ($DryRun) {
                $result.logsRotated++
                $result.bytesFreed += ($beforeLen - $keepBytes)
                continue
            }

            $stamp = (Get-Date).ToString('yyyyMMddHHmmss')
            $bak = "$($lf.FullName).$stamp.bak"
            $archiveZip = Join-Path $logsRoot ("$($lf.Name).archive.zip")

            try {
                Copy-Item -LiteralPath $lf.FullName -Destination $bak -Force -ErrorAction Stop
            } catch {
                Write-CleanupLog -Path $cleanupLog -Event 'cleanup-error' -Properties @{
                    target = $lf.FullName
                    action = 'backup-log'
                    reason = $_.Exception.Message
                }
                continue
            }

            $newLen = $null
            try {
                $newLen = Invoke-JsonlTailTruncate -Path $lf.FullName -KeepBytes $keepBytes
            } catch {
                Write-CleanupLog -Path $cleanupLog -Event 'cleanup-error' -Properties @{
                    target = $lf.FullName
                    action = 'truncate-log'
                    reason = $_.Exception.Message
                }
                continue
            }

            try {
                Add-FileToArchiveZip -SourceFile $bak -ZipPath $archiveZip
                Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
            } catch {
                Write-CleanupLog -Path $cleanupLog -Event 'cleanup-error' -Properties @{
                    target = $bak
                    action = 'zip-bak'
                    reason = $_.Exception.Message
                }
                # leave the .bak in place so user can recover manually
            }

            $result.logsRotated++
            if ($null -ne $newLen) {
                $result.bytesFreed += ($beforeLen - [int64]$newLen)
            }
        }
    }

    $sw.Stop()
    $result.durationMs = [int]$sw.ElapsedMilliseconds

    # --- 3) Structured cleanup log entry --------------------------------------
    Write-CleanupLog -Path $cleanupLog -Event 'cleanup-run' -Properties @{
        sessionsArchived = $result.sessionsArchived
        sessionsRemoved  = $result.sessionsRemoved
        logsRotated      = $result.logsRotated
        bytesFreed       = $result.bytesFreed
        durationMs       = $result.durationMs
        dryRun           = $result.dryRun
    }

    return [hashtable]$result
}

# ---------------------------------------------------------------------------
# Scheduled Task management
# ---------------------------------------------------------------------------

$Script:CleanupTaskName = 'AioxCleanup'

function Register-AioxCleanupTask {
    [CmdletBinding()]
    param(
        [string]$TaskName = $Script:CleanupTaskName,
        [int]$Hour   = 3,
        [int]$Minute = 0
    )

    $modulePath = (Resolve-Path "$PSScriptRoot\Cleanup.psm1").Path
    $cmd = "Import-Module '$modulePath' -Force; Invoke-AioxCleanup | Out-Null"
    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""

    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday `
        -At ([DateTime]::Today.AddHours($Hour).AddMinutes($Minute))

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null

    Write-Host "Registered scheduled task '$TaskName' (Sun ${Hour}:${Minute})." -ForegroundColor Green
}

function Unregister-AioxCleanupTask {
    [CmdletBinding()]
    param([string]$TaskName = $Script:CleanupTaskName)
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Unregistered scheduled task '$TaskName'." -ForegroundColor Yellow
    } else {
        Write-Host "Task '$TaskName' not registered." -ForegroundColor DarkGray
    }
}

function Enable-AioxCleanup {
    [CmdletBinding()]
    param([string]$TaskName = $Script:CleanupTaskName)
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Warning "Task '$TaskName' not registered. Run Register-AioxCleanupTask first."
        return
    }
    Enable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Host "Cleanup task ENABLED." -ForegroundColor Green
}

function Disable-AioxCleanup {
    [CmdletBinding()]
    param([string]$TaskName = $Script:CleanupTaskName)
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Warning "Task '$TaskName' not registered."
        return
    }
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Host "Cleanup task DISABLED." -ForegroundColor Yellow
}

Export-ModuleMember -Function `
    Invoke-AioxCleanup, `
    Register-AioxCleanupTask, `
    Unregister-AioxCleanupTask, `
    Enable-AioxCleanup, `
    Disable-AioxCleanup
