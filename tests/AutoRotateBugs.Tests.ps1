# tests/AutoRotateBugs.Tests.ps1 — Pester 5 tests for Task 5 bugfixes
# Validates the three helper functions that resolve BUG-A, BUG-B, BUG-C.
# These helpers live inside auto-rotate.ps1 / auto-rotate-codex.ps1 but are
# standalone enough to dot-source from a synthetic harness so we don't trigger
# the main rotation logic (which exits the script on missing state.json).

BeforeAll {
    $repoRoot   = Split-Path -Parent $PSScriptRoot
    $rotatePs1  = Join-Path $repoRoot 'auto-rotate.ps1'
    $codexPs1   = Join-Path $repoRoot 'auto-rotate-codex.ps1'
    $logger     = Join-Path $repoRoot 'aiox-shared\StructuredLogger.psm1'

    if (-not (Test-Path -LiteralPath $rotatePs1)) {
        throw "auto-rotate.ps1 not found at $rotatePs1"
    }
    if (-not (Test-Path -LiteralPath $codexPs1)) {
        throw "auto-rotate-codex.ps1 not found at $codexPs1"
    }

    Import-Module $logger -Force

    # Extract function bodies via regex so the script's "main" code (which
    # exits on missing state.json) does not run when we dot-source.
    function Get-PsFunctionText {
        param([string]$ScriptPath, [string]$FunctionName)
        $text  = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
        $regex = "(?ms)^function\s+$([regex]::Escape($FunctionName))\s*\{.*?^\}"
        $m     = [regex]::Match($text, $regex)
        if (-not $m.Success) { throw "Function $FunctionName not found in $ScriptPath" }
        return $m.Value
    }

    # Per-test isolated log file
    $script:JsonLogFile = Join-Path ([System.IO.Path]::GetTempPath()) ("autorotatebugs-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))

    # Load helper functions into this scope
    $fnNames = @('Test-IsValidProfileName', 'ConvertTo-UtcDateTime', 'Read-CooldownFile')
    foreach ($fn in $fnNames) {
        $body = Get-PsFunctionText -ScriptPath $rotatePs1 -FunctionName $fn
        Invoke-Expression $body
    }
}

Describe "Profile name regex (BUG-A)" {
    It "Accepts lowercase profile names" {
        Test-IsValidProfileName 'claude-a' | Should -Be $true
    }
    It "Accepts uppercase profile names" {
        Test-IsValidProfileName 'CLAUDE-A' | Should -Be $true
    }
    It "Accepts mixed case profile names" {
        Test-IsValidProfileName 'Claude-A' | Should -Be $true
    }
    It "Rejects names that do not match the schema" {
        Test-IsValidProfileName 'claude-ab' | Should -Be $false
        Test-IsValidProfileName 'claude'    | Should -Be $false
        Test-IsValidProfileName 'codex-a'   | Should -Be $false
        Test-IsValidProfileName ''          | Should -Be $false
    }
}

Describe "DateTime parsing (BUG-B)" {
    It "Treats ISO 8601 Z strings as UTC" {
        $dt = ConvertTo-UtcDateTime '2026-05-10T15:30:00Z'
        $dt.Kind         | Should -Be 'Utc'
        $dt.Year         | Should -Be 2026
        $dt.Month        | Should -Be 5
        $dt.Day          | Should -Be 10
        $dt.Hour         | Should -Be 15
        $dt.Minute       | Should -Be 30
    }
    It "Treats unqualified ISO strings as UTC (does not shift by local offset)" {
        # An unqualified timestamp must be assumed UTC, not local — otherwise
        # cooldown checks fire at the wrong time on machines that aren't in UTC.
        $dt = ConvertTo-UtcDateTime '2026-05-10T15:30:00'
        $dt.Kind   | Should -Be 'Utc'
        $dt.Hour   | Should -Be 15
        $dt.Minute | Should -Be 30
    }
    It "Normalizes offsets to UTC" {
        # 12:00-03:00 == 15:00 UTC
        $dt = ConvertTo-UtcDateTime '2026-05-10T12:00:00-03:00'
        $dt.Kind | Should -Be 'Utc'
        $dt.Hour | Should -Be 15
    }
}

Describe "Cooldown file read (BUG-C)" {
    BeforeEach {
        $script:JsonLogFile = Join-Path ([System.IO.Path]::GetTempPath()) ("autorotatebugs-{0}.jsonl" -f ([Guid]::NewGuid().ToString('N')))
    }

    It "Returns the parsed long when the file is well-formed" {
        $tmp = New-TemporaryFile
        Set-Content -LiteralPath $tmp -Value '1746889200' -Encoding UTF8
        $result = Read-CooldownFile -Path $tmp
        $result | Should -Be 1746889200
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    It "Returns null and logs a structured 'corrupt-cooldown' event when content is not numeric" {
        $tmp = New-TemporaryFile
        Set-Content -LiteralPath $tmp -Value 'NOT_A_NUMBER' -Encoding UTF8

        $result = Read-CooldownFile -Path $tmp

        $result | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:JsonLogFile | Should -BeTrue
        $logLine = Get-Content -LiteralPath $script:JsonLogFile -Tail 1
        $obj = $logLine | ConvertFrom-Json
        $obj.event | Should -Be 'corrupt-cooldown'
        $obj.level | Should -Be 'error'
        $obj.path  | Should -Be ([string]$tmp)

        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    It "Returns null and logs when the file does not exist" {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-{0}.cooldown" -f ([Guid]::NewGuid().ToString('N')))
        $result  = Read-CooldownFile -Path $missing
        $result | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:JsonLogFile | Should -BeTrue
        $logLine = Get-Content -LiteralPath $script:JsonLogFile -Tail 1
        $obj = $logLine | ConvertFrom-Json
        $obj.event | Should -Be 'corrupt-cooldown'
    }
}
