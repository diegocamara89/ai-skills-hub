#Requires -Version 7.0
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# tests/OAuthRefresh.Tests.ps1
#
# Plan: docs/superpowers/plans/2026-05-10-evolution-d.md  Task 8
#
# Coverage:
#   1) Skip refresh when expiresIn >= 300 (healthy token).
#   2) Trigger refresh exactly once when expiresIn < 300 (and helper succeeds).
#   3) Retry exactly 3 times (1s+2s of backoff) when helper keeps throwing.
#   4) Each event written to the JSON-lines log is valid JSON with the required
#      fields (ts, level, event, cliType, profileName).
#
# All external calls are isolated via Pester Mocks:
#   - Get-CliAuthInfo            -> returns synthetic auth-info hashtable
#   - Invoke-ClaudeAuthRefresh   -> mocked success/failure
#   - Start-Sleep                -> mocked to a no-op so retry tests stay fast

BeforeAll {
    $script:HubRoot   = (Resolve-Path "$PSScriptRoot/..").Path
    $script:LibScript = Join-Path $script:HubRoot 'lib\oauth-refresh.ps1'
    . $script:LibScript

    # Helper: spin up a fresh log file per test.
    function script:New-TempLogPath {
        $dir = Join-Path $env:TEMP ("oauth-refresh-test-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return (Join-Path $dir 'oauth-refresh.jsonl')
    }
}

Describe "Invoke-OAuthRefreshIfNeeded" {

    BeforeEach {
        $script:logPath = New-TempLogPath
    }

    AfterEach {
        if ($script:logPath) {
            $parent = Split-Path -Parent $script:logPath
            if (Test-Path -LiteralPath $parent) {
                Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "when token still healthy (expiresIn >= 300)" {

        It "Skips refresh and returns true without invoking the refresh helper" {
            Mock Get-CliAuthInfo {
                return [ordered]@{ accessTokenExpiresIn = 600 }
            }
            Mock Invoke-ClaudeAuthRefresh { }

            $result = Invoke-OAuthRefreshIfNeeded `
                -CliType 'claude' `
                -ProfileName 'claude-a' `
                -ConfigDirOverride 'C:\fake\claude-a' `
                -LogPath $script:logPath

            $result | Should -Be $true
            Should -Invoke Invoke-ClaudeAuthRefresh -Times 0 -Exactly
        }
    }

    Context "when token near expiry (expiresIn < 300)" {

        It "Calls Invoke-ClaudeAuthRefresh once when helper succeeds on attempt 1" {
            # First call: expiresIn=200 (drives trigger). Second call: post-refresh
            # confirmation -> healthy 3600.
            $script:authCallCount = 0
            Mock Get-CliAuthInfo {
                $script:authCallCount++
                if ($script:authCallCount -eq 1) {
                    return [ordered]@{ accessTokenExpiresIn = 200 }
                } else {
                    return [ordered]@{ accessTokenExpiresIn = 3600 }
                }
            }
            Mock Invoke-ClaudeAuthRefresh { return @{ success = $true } }
            Mock Start-Sleep { }   # never sleep in tests

            $result = Invoke-OAuthRefreshIfNeeded `
                -CliType 'claude' `
                -ProfileName 'claude-a' `
                -ConfigDirOverride 'C:\fake\claude-a' `
                -LogPath $script:logPath

            $result | Should -Be $true
            Should -Invoke Invoke-ClaudeAuthRefresh -Times 1 -Exactly
        }
    }

    Context "when refresh helper keeps failing" {

        It "Retries exactly 3 times then returns false" {
            Mock Get-CliAuthInfo {
                return [ordered]@{ accessTokenExpiresIn = 100 }
            }
            Mock Invoke-ClaudeAuthRefresh { throw "simulated 401" }
            Mock Start-Sleep { }   # mock sleep so test runs fast

            $result = Invoke-OAuthRefreshIfNeeded `
                -CliType 'claude' `
                -ProfileName 'claude-a' `
                -ConfigDirOverride 'C:\fake\claude-a' `
                -LogPath $script:logPath

            $result | Should -Be $false
            Should -Invoke Invoke-ClaudeAuthRefresh -Times 3 -Exactly
            # backoff schedule: 1s + 2s = 2 sleeps between 3 attempts
            Should -Invoke Start-Sleep -Times 2 -Exactly
        }
    }

    Context "structured log emission" {

        It "Writes valid JSON-lines with required fields for skip + attempt + success" {
            $script:authCallCount = 0
            Mock Get-CliAuthInfo {
                $script:authCallCount++
                if ($script:authCallCount -eq 1) {
                    # First top-level call: trigger refresh
                    return [ordered]@{ accessTokenExpiresIn = 100 }
                } else {
                    # Post-refresh check
                    return [ordered]@{ accessTokenExpiresIn = 3600 }
                }
            }
            Mock Invoke-ClaudeAuthRefresh { return @{ success = $true } }
            Mock Start-Sleep { }

            Invoke-OAuthRefreshIfNeeded `
                -CliType 'claude' `
                -ProfileName 'claude-a' `
                -ConfigDirOverride 'C:\fake\claude-a' `
                -LogPath $script:logPath | Out-Null

            Test-Path -LiteralPath $script:logPath | Should -Be $true

            $lines = Get-Content -LiteralPath $script:logPath
            $lines.Count | Should -BeGreaterThan 0

            # Validate raw JSON text (ts as string) FIRST, then parse.
            # PS7's ConvertFrom-Json auto-promotes ISO 8601 strings to [datetime],
            # whose default ToString() is locale-formatted and breaks regex matching
            # against the original ISO format. Two-stage check sidesteps that.
            $events = @()
            foreach ($line in $lines) {
                # Stage 1: raw text contains a "ts":"<iso>" pair
                $line | Should -Match '"ts":"\d{4}-\d{2}-\d{2}T'

                # Stage 2: structural validation via parsed object
                { $line | ConvertFrom-Json } | Should -Not -Throw
                $obj = $line | ConvertFrom-Json
                $obj.level       | Should -BeIn @('info','warn','error','debug')
                $obj.event       | Should -Not -BeNullOrEmpty
                $obj.cliType     | Should -Be 'claude'
                $obj.profileName | Should -Be 'claude-a'
                $events += $obj.event
            }

            # Expected sequence on a successful trigger: attempt -> success
            $events | Should -Contain 'oauth-refresh-attempt'
            $events | Should -Contain 'oauth-refresh-success'
        }
    }
}
