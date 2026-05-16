# aiox-shared/tests/StructuredLogger.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../StructuredLogger.psm1" -Force
}

Describe "Write-StructuredLog" {
    BeforeEach {
        $tmp = New-TemporaryFile
        # New-TemporaryFile creates an empty file; remove so logger creates fresh.
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $script:logFile = $tmp.FullName
    }

    AfterEach {
        if ($script:logFile -and (Test-Path -LiteralPath $script:logFile)) {
            Remove-Item -LiteralPath $script:logFile -Force -ErrorAction SilentlyContinue
        }
    }

    It "Writes JSON object per line with required fields" {
        Write-StructuredLog -Path $script:logFile -Event 'rotate' -Properties @{
            from = 'claude-a'; to = 'claude-b'; usedPct = 97
        }
        $line = Get-Content -LiteralPath $script:logFile -Tail 1
        $obj = $line | ConvertFrom-Json
        $obj.event | Should -Be 'rotate'
        $obj.from | Should -Be 'claude-a'
        $obj.to | Should -Be 'claude-b'
        $obj.usedPct | Should -Be 97
        # NOTE: ConvertFrom-Json auto-parses ts -> [DateTime], so we regex
        # against the raw JSON line to confirm the on-disk ISO 8601 format.
        $line | Should -Match '"ts":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $obj.level | Should -Be 'info'
    }

    It "Appends — does not overwrite previous entries" {
        Write-StructuredLog -Path $script:logFile -Event 'a'
        Write-StructuredLog -Path $script:logFile -Event 'b'
        $lines = Get-Content -LiteralPath $script:logFile
        $lines.Count | Should -Be 2
    }

    It "Each line is valid standalone JSON" {
        Write-StructuredLog -Path $script:logFile -Event 'rotate' -Level 'warn'
        $line = Get-Content -LiteralPath $script:logFile -Tail 1
        { $line | ConvertFrom-Json } | Should -Not -Throw
    }
}
