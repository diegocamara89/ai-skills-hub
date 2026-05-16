# aiox-shared/tests/Cleanup.Tests.ps1
# Pester 5 tests for Invoke-AioxCleanup. Uses TestDrive exclusively; never
# touches the real user state. All paths are routed through the *Override
# parameters of Invoke-AioxCleanup.

BeforeAll {
    Import-Module "$PSScriptRoot/../Cleanup.psm1" -Force

    function New-FakeSession {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][datetime]$Mtime,
            [int]$Bytes = 1024
        )
        $folder = Join-Path $script:authRoot $Name
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $file = Join-Path $folder 'session.json'
        $payload = [System.Text.Encoding]::UTF8.GetBytes(('x' * $Bytes))
        [System.IO.File]::WriteAllBytes($file, $payload)
        (Get-Item -LiteralPath $file).LastWriteTime   = $Mtime
        (Get-Item -LiteralPath $folder).LastWriteTime = $Mtime
        return $folder
    }

    function New-FakeJsonlLog {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][int]$SizeMB
        )
        $path = Join-Path $script:logsRoot $Name
        # Write SizeMB worth of "{\"k\":\"v\"}\n" lines.
        $line = '{"k":"v"}' + "`n"
        $bytesPerLine = [System.Text.Encoding]::UTF8.GetByteCount($line)
        $totalBytes   = $SizeMB * 1024 * 1024
        $linesNeeded  = [int][math]::Ceiling($totalBytes / $bytesPerLine)
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Create)
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            $bytes = $utf8NoBom.GetBytes($line)
            for ($i = 0; $i -lt $linesNeeded; $i++) {
                $fs.Write($bytes, 0, $bytes.Length)
            }
        } finally {
            $fs.Dispose()
        }
        return $path
    }

    function Invoke-CleanupHelper {
        param([switch]$DryRun, [int]$SessionDays = 14, [int]$Max = 50, [int]$Keep = 25)
        Invoke-AioxCleanup `
            -SessionDaysToKeep $SessionDays `
            -LogMaxSizeMB $Max `
            -LogTruncateToMB $Keep `
            -DryRun:$DryRun `
            -AuthRootOverride    $script:authRoot `
            -AuthArchiveOverride $script:authArchive `
            -LogsRootOverride    $script:logsRoot `
            -CleanupLogOverride  $script:cleanupLog
    }
}

Describe "Invoke-AioxCleanup" {

    BeforeEach {
        $script:authRoot    = Join-Path $TestDrive 'state\claude-auth'
        $script:authArchive = Join-Path $TestDrive 'state\claude-auth-archive'
        $script:logsRoot    = Join-Path $TestDrive 'usage\logs'
        $script:cleanupLog  = Join-Path $script:logsRoot 'cleanup.jsonl'
        # Wipe between tests to avoid cross-contamination.
        if (Test-Path -LiteralPath $script:authRoot)    { Remove-Item -LiteralPath $script:authRoot    -Recurse -Force }
        if (Test-Path -LiteralPath $script:authArchive) { Remove-Item -LiteralPath $script:authArchive -Recurse -Force }
        if (Test-Path -LiteralPath $script:logsRoot)    { Remove-Item -LiteralPath $script:logsRoot    -Recurse -Force }
        New-Item -ItemType Directory -Path $script:authRoot   -Force | Out-Null
        New-Item -ItemType Directory -Path $script:logsRoot   -Force | Out-Null
    }

    It "DryRun does not modify disk (sessions intact, no zip, no cleanup.jsonl-touched bak)" {
        $old = New-FakeSession -Name 'old-1' -Mtime ((Get-Date).AddDays(-30))
        $result = Invoke-CleanupHelper -DryRun
        Test-Path -LiteralPath $old                        | Should -BeTrue
        Test-Path -LiteralPath $script:authArchive          | Should -BeFalse
        $result.dryRun                                       | Should -BeTrue
        $result.sessionsArchived                             | Should -BeGreaterThan 0
    }

    It "Old session (>14 days) is archived and deleted" {
        $old = New-FakeSession -Name 'old-2' -Mtime ((Get-Date).AddDays(-30))
        $result = Invoke-CleanupHelper
        Test-Path -LiteralPath $old                          | Should -BeFalse
        $result.sessionsArchived                             | Should -Be 1
        $result.sessionsRemoved                              | Should -Be 1
        # Zip exists under YYYY-MM bucket.
        $bucket = (Get-Date).AddDays(-30).ToString('yyyy-MM')
        Test-Path -LiteralPath (Join-Path $script:authArchive "$bucket.zip") | Should -BeTrue
    }

    It "Recent session (<14 days) is preserved" {
        $recent = New-FakeSession -Name 'recent-1' -Mtime ((Get-Date).AddDays(-3))
        $result = Invoke-CleanupHelper
        Test-Path -LiteralPath $recent                       | Should -BeTrue
        $result.sessionsArchived                             | Should -Be 0
    }

    It "Monthly zip is appended when it already exists" {
        $mtime = (Get-Date).AddDays(-30)
        $bucket = $mtime.ToString('yyyy-MM')
        $zipPath = Join-Path $script:authArchive "$bucket.zip"

        $a = New-FakeSession -Name 'old-a' -Mtime $mtime
        Invoke-CleanupHelper | Out-Null
        $sizeAfterFirst = (Get-Item -LiteralPath $zipPath).Length

        $b = New-FakeSession -Name 'old-b' -Mtime $mtime
        Invoke-CleanupHelper | Out-Null
        $sizeAfterSecond = (Get-Item -LiteralPath $zipPath).Length

        $sizeAfterSecond | Should -BeGreaterThan $sizeAfterFirst

        # Verify both entries are present inside the zip.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $names = $zip.Entries | ForEach-Object { $_.FullName }
        } finally {
            $zip.Dispose()
        }
        ($names -join "`n") | Should -Match 'old-a'
        ($names -join "`n") | Should -Match 'old-b'
    }

    It "JSONL log >50MB is truncated to ~25MB" {
        $log = New-FakeJsonlLog -Name 'rotation.jsonl' -SizeMB 60
        $before = (Get-Item -LiteralPath $log).Length
        $result = Invoke-CleanupHelper -Max 50 -Keep 25
        $after  = (Get-Item -LiteralPath $log).Length
        $result.logsRotated | Should -Be 1
        $after | Should -BeLessThan $before
        # Tail keeps at most ~25MB. Allow a single-line slack from newline alignment.
        $after | Should -BeLessOrEqual (25 * 1024 * 1024)
        # Should still be the majority of the keep window.
        $after | Should -BeGreaterThan (20 * 1024 * 1024)
    }

    It "JSONL log under threshold is preserved" {
        $log = New-FakeJsonlLog -Name 'rotation.jsonl' -SizeMB 5
        $before = (Get-Item -LiteralPath $log).Length
        $result = Invoke-CleanupHelper -Max 50 -Keep 25
        $after  = (Get-Item -LiteralPath $log).Length
        $after  | Should -Be $before
        $result.logsRotated | Should -Be 0
    }

    It "Backup is archived (and original .bak removed) after rotation" {
        $log = New-FakeJsonlLog -Name 'rotation.jsonl' -SizeMB 60
        Invoke-CleanupHelper -Max 50 -Keep 25 | Out-Null
        # Archive zip exists.
        Test-Path -LiteralPath (Join-Path $script:logsRoot 'rotation.jsonl.archive.zip') | Should -BeTrue
        # Loose .bak files should have been zipped then removed.
        @(Get-ChildItem -LiteralPath $script:logsRoot -Filter '*.bak' -ErrorAction SilentlyContinue).Count |
            Should -Be 0
    }

    It "Result reports bytesFreed > 0 when work occurred" {
        New-FakeSession -Name 'old-3' -Mtime ((Get-Date).AddDays(-30)) -Bytes 8192 | Out-Null
        $result = Invoke-CleanupHelper
        $result.bytesFreed | Should -BeGreaterThan 0
        $result.durationMs | Should -BeGreaterOrEqual 0
    }

    It "cleanup.jsonl receives a structured cleanup-run entry" {
        New-FakeSession -Name 'old-4' -Mtime ((Get-Date).AddDays(-30)) | Out-Null
        $r = Invoke-CleanupHelper
        Test-Path -LiteralPath $script:cleanupLog | Should -BeTrue
        $lines = @(Get-Content -LiteralPath $script:cleanupLog | Where-Object { $_ -match '\S' })
        $lines.Count | Should -BeGreaterOrEqual 1
        # Find the last 'cleanup-run' entry (there may be 'cleanup-error' entries before it).
        $runLines = @($lines | Where-Object { $_ -match '"event":"cleanup-run"' })
        $runLines.Count | Should -BeGreaterOrEqual 1
        $obj = $runLines[-1] | ConvertFrom-Json
        $obj.event             | Should -Be 'cleanup-run'
        $obj.sessionsArchived  | Should -Be $r.sessionsArchived
        $obj.logsRotated       | Should -Be $r.logsRotated
        $obj.bytesFreed        | Should -Be $r.bytesFreed
        $obj.dryRun            | Should -Be $false
    }
}
