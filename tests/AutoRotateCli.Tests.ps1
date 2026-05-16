# tests/AutoRotateCli.Tests.ps1 — Pester 5 tests for Task 3 CLI modes
# Validates the four CLI modes added to auto-rotate.ps1:
#   -Status   : prints active profile + 5h/7d %
#   -List     : enumerates profiles with state/cooldown
#   -Preview  : shows next-available profile WITHOUT touching the junction
#   -Switch   : with -DryRun, emits structured 'rotate' event without applying
#
# Tests invoke the real auto-rotate.ps1 in a child pwsh process so we exercise
# the param block + dispatch as a user would. They depend on the real
# ~/.claude-orchestrator/{state.json,config.json} being present.
#
# IMPORTANT (Pester 5 scoping):
#  - `-Skip:(...)` is evaluated at DISCOVERY — must use top-level vars
#  - Variables used INSIDE `It {}` are evaluated at RUN — must come from
#    BeforeAll, which uses $script: scope to publish them.

# Top-level (discovery-time) booleans for -Skip filters
$DiscRoot      = Split-Path -Parent $PSScriptRoot
$DiscRotate    = Join-Path $DiscRoot 'auto-rotate.ps1'
$DiscState     = Join-Path $env:USERPROFILE '.claude-orchestrator\state.json'
$DiscConfig    = Join-Path $env:USERPROFILE '.claude-orchestrator\config.json'
$DiscActive    = Join-Path $env:USERPROFILE '.claude-profiles\active'
$HasRotatePs1  = Test-Path -LiteralPath $DiscRotate
$HasState      = (Test-Path -LiteralPath $DiscState) -and (Test-Path -LiteralPath $DiscConfig)
$HasActiveLink = Test-Path -LiteralPath $DiscActive

if (-not $HasRotatePs1) { throw "auto-rotate.ps1 not found at $DiscRotate" }

BeforeAll {
    # Run-time vars (visible inside It blocks via $script:)
    $script:rotatePs1   = Join-Path (Split-Path -Parent $PSScriptRoot) 'auto-rotate.ps1'
    $script:stateFile   = Join-Path $env:USERPROFILE '.claude-orchestrator\state.json'
    $script:configFile  = Join-Path $env:USERPROFILE '.claude-orchestrator\config.json'
    $script:jsonLogFile = Join-Path $env:USERPROFILE '.claude-orchestrator\usage\logs\rotation.jsonl'
    $script:activeLink  = Join-Path $env:USERPROFILE '.claude-profiles\active'
}

Describe "auto-rotate CLI modes" {

    Context "Status mode" {
        It "Prints active profile + percent without changing state" -Skip:(-not $HasState) {
            $beforeJunction = $null
            if (Test-Path -LiteralPath $script:activeLink) {
                $beforeJunction = (Get-Item -LiteralPath $script:activeLink -Force).Target | Select-Object -First 1
            }
            $beforeStateHash = (Get-FileHash -LiteralPath $script:stateFile -Algorithm SHA256).Hash

            $output = & pwsh -NoProfile -File $script:rotatePs1 -Status -DryRun 2>&1
            $joined = ($output | Out-String)

            $joined | Should -Match 'Active:'
            $joined | Should -Match '\d+\s*%'

            $afterJunction = $null
            if (Test-Path -LiteralPath $script:activeLink) {
                $afterJunction = (Get-Item -LiteralPath $script:activeLink -Force).Target | Select-Object -First 1
            }
            $afterStateHash = (Get-FileHash -LiteralPath $script:stateFile -Algorithm SHA256).Hash
            $afterJunction  | Should -Be $beforeJunction
            $afterStateHash | Should -Be $beforeStateHash
        }
    }

    Context "List mode" {
        It "Enumerates all profiles with state column" -Skip:(-not $HasState) {
            $output = & pwsh -NoProfile -File $script:rotatePs1 -List 2>&1
            $joined = ($output | Out-String)
            $joined | Should -Match 'claude-a'
            $joined | Should -Match '(available|cooldown|auth_required)'
        }
    }

    Context "Preview mode" {
        It "Does not change the active junction" -Skip:(-not $HasActiveLink) {
            $beforeTarget = (Get-Item -LiteralPath $script:activeLink -Force).Target | Select-Object -First 1
            $null = & pwsh -NoProfile -File $script:rotatePs1 -Preview 2>&1
            $afterTarget  = (Get-Item -LiteralPath $script:activeLink -Force).Target | Select-Object -First 1
            $afterTarget | Should -Be $beforeTarget
        }
    }

    Context "Switch mode (dry-run)" {
        It "Emits a structured rotate event with triggerReason manual-switch and does not change state" -Skip:(-not $HasState) {
            $stateObj = Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $activeNow = $null
            if (Test-Path -LiteralPath $script:activeLink) {
                $activeNow = (Get-Item -LiteralPath $script:activeLink -Force).Target | Select-Object -First 1 | Split-Path -Leaf
            }
            if (-not $activeNow) { $activeNow = [string]$stateObj.active_profile }
            $target = if ($activeNow -eq 'claude-b') { 'claude-c' } else { 'claude-b' }

            $beforeStateHash = (Get-FileHash -LiteralPath $script:stateFile -Algorithm SHA256).Hash
            $beforeJunction = $null
            if (Test-Path -LiteralPath $script:activeLink) {
                $beforeJunction = (Get-Item -LiteralPath $script:activeLink -Force).Target | Select-Object -First 1
            }

            & pwsh -NoProfile -File $script:rotatePs1 -Switch $target -DryRun 2>&1 | Out-Null

            $afterStateHash = (Get-FileHash -LiteralPath $script:stateFile -Algorithm SHA256).Hash
            $afterJunction = $null
            if (Test-Path -LiteralPath $script:activeLink) {
                $afterJunction = (Get-Item -LiteralPath $script:activeLink -Force).Target | Select-Object -First 1
            }
            $afterStateHash | Should -Be $beforeStateHash
            $afterJunction  | Should -Be $beforeJunction

            Test-Path -LiteralPath $script:jsonLogFile | Should -BeTrue
            $allLines = Get-Content -LiteralPath $script:jsonLogFile -Encoding UTF8
            $allLines.Count | Should -BeGreaterThan 0

            # The most-recent 'rotate' event is the one we just emitted.
            $rotateLine = $allLines | Where-Object {
                try { ($_ | ConvertFrom-Json).event -eq 'rotate' } catch { $false }
            } | Select-Object -Last 1
            $rotateLine | Should -Not -BeNullOrEmpty
            $rotateObj = $rotateLine | ConvertFrom-Json
            $rotateObj.event         | Should -Be 'rotate'
            $rotateObj.triggerReason | Should -Be 'manual-switch'
            $rotateObj.to            | Should -Be $target
            $rotateObj.dryRun        | Should -BeTrue
        }
    }
}
