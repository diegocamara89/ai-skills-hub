#Requires -Version 7.0
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# tests/VpsAuthSyncSelective.Tests.ps1
#
# Cobre o fix do bug raiz: vps_ai_auth_sync.py SEMPRE empurrava Claude E Codex
# juntos. Quando o user logava so Claude no painel, o sync empurrava tambem
# o ~/.codex/auth.json LOCAL (stale) sobre o auth-profiles.json da VPS que
# tinha Codex valido. Resultado: Codex regredia de VALIDO -> EXPIRED.
#
# Esta suite valida:
#   1. --only=claude bloqueia push_codex no JSON output
#   2. --only=codex  bloqueia push_claude no JSON output
#   3. ausencia de --only mantem comportamento legado (both)
#   4. needs_sync nao empurra quando remote.expires > local.expires + 60s
#   5. needs_sync nao empurra quando remote.expires == local.expires (mesmo fp)
#   6. needs_sync empurra quando remote.expires < local.expires
#
# Casos 1-3: invocam o Python real com --dry-run para evitar SSH para VPS.
# Casos 4-6: delegam para tests/test_vps_sync_anti_regression.py via subprocess.

BeforeAll {
    $script:SyncScriptPath = Join-Path $env:USERPROFILE 'Diego\VPS\Oracle\ClowdBot\scripts\vps_ai_auth_sync.py'
    $script:AntiRegressionPy = Join-Path $PSScriptRoot 'test_vps_sync_anti_regression.py'

    function script:Get-PythonExe {
        $candidates = @('python', 'py')
        foreach ($candidate in $candidates) {
            $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
        }
        return $null
    }

    function script:Invoke-PythonJson {
        param([string[]]$Arguments)
        $py = script:Get-PythonExe
        if (-not $py) { throw 'python_not_found' }
        $stdoutFile = Join-Path $TestDrive ("py-stdout-" + [guid]::NewGuid() + ".txt")
        $stderrFile = Join-Path $TestDrive ("py-stderr-" + [guid]::NewGuid() + ".txt")
        $proc = Start-Process -FilePath $py `
            -ArgumentList $Arguments `
            -NoNewWindow `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -PassThru -Wait
        $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw } else { "" }
        $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { "" }
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout   = $stdout
            Stderr   = $stderr
        }
    }

    function script:Make-FakeClaudeProfileDir {
        $dir = Join-Path $TestDrive ("claude-fake-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # Build a minimal but valid .credentials.json so extract_claude_state
        # marks present=true (refresh + access + expiresAt all required).
        $payload = [ordered]@{
            organizationUuid = 'org-test'
            claudeAiOauth    = [ordered]@{
                accessToken  = 'header.eyJleHAiOjk5OTk5OTk5OTl9.sig'
                refreshToken = 'fake-refresh'
                expiresAt    = 9999999999000
            }
        } | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath (Join-Path $dir '.credentials.json') -Value $payload -Encoding UTF8
        return $dir
    }

    function script:Make-FakeCodexAuthFile {
        $dir = Join-Path $TestDrive ("codex-fake-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'auth.json'
        $payload = [ordered]@{
            tokens = [ordered]@{
                access_token  = 'header.eyJleHAiOjk5OTk5OTk5OTl9.sig'
                refresh_token = 'fake-refresh'
                account_id    = 'acct-test'
            }
        } | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $path -Value $payload -Encoding UTF8
        return $path
    }
}

Describe "vps_ai_auth_sync.py --only flag (selective push)" {
    BeforeAll {
        if (-not (Test-Path -LiteralPath $script:SyncScriptPath)) {
            throw "sync_script_missing:$script:SyncScriptPath"
        }
        if (-not (script:Get-PythonExe)) {
            throw "python_not_available_on_PATH"
        }
    }

    It "Test 1: --only=claude returns push_codex=false in JSON output" {
        $claudeDir = script:Make-FakeClaudeProfileDir
        $codexFile = script:Make-FakeCodexAuthFile
        $args = @(
            $script:SyncScriptPath,
            '--json',
            '--dry-run',
            '--only=claude',
            '--claude-source', $claudeDir,
            '--codex-source', $codexFile
        )
        $r = script:Invoke-PythonJson -Arguments $args
        $r.ExitCode | Should -Be 0
        $r.Stdout   | Should -Not -BeNullOrEmpty
        $obj = $r.Stdout | ConvertFrom-Json
        [bool]$obj.push_codex  | Should -Be $false
        [bool]$obj.push_claude | Should -Be $true
        [string]$obj.only      | Should -Be 'claude'
    }

    It "Test 2: --only=codex returns push_claude=false in JSON output" {
        $claudeDir = script:Make-FakeClaudeProfileDir
        $codexFile = script:Make-FakeCodexAuthFile
        $args = @(
            $script:SyncScriptPath,
            '--json',
            '--dry-run',
            '--only=codex',
            '--claude-source', $claudeDir,
            '--codex-source', $codexFile
        )
        $r = script:Invoke-PythonJson -Arguments $args
        $r.ExitCode | Should -Be 0
        $obj = $r.Stdout | ConvertFrom-Json
        [bool]$obj.push_claude | Should -Be $false
        [bool]$obj.push_codex  | Should -Be $true
        [string]$obj.only      | Should -Be 'codex'
    }

    It "Test 3: no --only flag preserves legacy behaviour (only=both, pushes both)" {
        $claudeDir = script:Make-FakeClaudeProfileDir
        $codexFile = script:Make-FakeCodexAuthFile
        $args = @(
            $script:SyncScriptPath,
            '--json',
            '--dry-run',
            '--claude-source', $claudeDir,
            '--codex-source', $codexFile
        )
        $r = script:Invoke-PythonJson -Arguments $args
        $r.ExitCode | Should -Be 0
        $obj = $r.Stdout | ConvertFrom-Json
        [bool]$obj.push_claude | Should -Be $true
        [bool]$obj.push_codex  | Should -Be $true
        [string]$obj.only      | Should -Be 'both'
    }
}

Describe "needs_sync anti-regression guard" {
    BeforeAll {
        if (-not (Test-Path -LiteralPath $script:AntiRegressionPy)) {
            throw "anti_regression_py_missing:$script:AntiRegressionPy"
        }
        if (-not (script:Get-PythonExe)) {
            throw "python_not_available_on_PATH"
        }
        $script:AntiResult = script:Invoke-PythonJson -Arguments @($script:AntiRegressionPy)
    }

    It "Anti-regression Python suite exits 0 (all cases pass)" {
        $script:AntiResult.ExitCode | Should -Be 0 -Because "stderr: $($script:AntiResult.Stderr); stdout: $($script:AntiResult.Stdout)"
    }

    It "Test 4: remote.expires > local.expires + 60s -> needs_sync returns False" {
        $obj = $script:AntiResult.Stdout | ConvertFrom-Json
        $failures = @($obj.failures | Where-Object { $_.case -eq 'anti_regression_remote_newer' })
        $failures.Count | Should -Be 0
    }

    It "Test 5: remote.expires == local.expires (same fingerprint) -> needs_sync returns False" {
        $obj = $script:AntiResult.Stdout | ConvertFrom-Json
        $failures = @($obj.failures | Where-Object { $_.case -eq 'equal_expires_same_fp_no_push' })
        $failures.Count | Should -Be 0
    }

    It "Test 6: remote.expires older than local.expires -> needs_sync returns True" {
        $obj = $script:AntiResult.Stdout | ConvertFrom-Json
        $failures = @($obj.failures | Where-Object { $_.case -eq 'local_newer_pushes' })
        $failures.Count | Should -Be 0
    }
}
