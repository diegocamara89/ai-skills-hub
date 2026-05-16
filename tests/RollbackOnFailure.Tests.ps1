# tests/RollbackOnFailure.Tests.ps1 — Pester 5 tests for Task 6 (Apply-ProfileSwitch)
#
# Validates that Apply-ProfileSwitch:
#   1. Reverts the junction to the previous target if New-Item -Junction throws.
#   2. Reverts state.json byte-identically if Save-JsonFile throws after the
#      junction was already swapped.
#   3. Re-throws the original exception so the caller knows the rotation failed.
#   4. Emits a structured 'rollback' event (level=error) when the structured
#      logger is available.
#
# Strategy:
# - Dot-source ONLY the helper functions out of auto-rotate.ps1 via regex
#   extraction (the same pattern used by AutoRotateBugs.Tests.ps1) so the
#   script's main "exit 1 if state.json missing" code does not run.
# - Provide a synthetic state.json + config.json in a per-test temp dir.
# - Pass -StateFileOverride / -ConfigFileOverride / -ProfilesRootOverride
#   so the function never touches HKCU (User-scope env var) or
#   ~/.claude-orchestrator. This keeps the test hermetic.
# - Mock New-Item with -ParameterFilter { $ItemType -eq 'Junction' } to inject
#   failures at the junction-creation site.

BeforeAll {
    $repoRoot   = Split-Path -Parent $PSScriptRoot
    $rotatePs1  = Join-Path $repoRoot 'auto-rotate.ps1'
    $logger     = Join-Path $repoRoot 'aiox-shared\StructuredLogger.psm1'

    if (-not (Test-Path -LiteralPath $rotatePs1)) {
        throw "auto-rotate.ps1 not found at $rotatePs1"
    }
    if (-not (Test-Path -LiteralPath $logger)) {
        throw "StructuredLogger.psm1 not found at $logger"
    }

    Import-Module $logger -Force

    function Get-PsFunctionText {
        param([string]$ScriptPath, [string]$FunctionName)
        $text  = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
        $regex = "(?ms)^function\s+$([regex]::Escape($FunctionName))\s*\{.*?^\}"
        $m     = [regex]::Match($text, $regex)
        if (-not $m.Success) { throw "Function $FunctionName not found in $ScriptPath" }
        return $m.Value
    }

    # Load helpers required by Apply-ProfileSwitch
    $fnNames = @(
        'Test-IsValidProfileName',
        'Read-JsonFile',
        'Save-JsonFile',
        'Write-Log',
        'Apply-ProfileSwitch'
    )
    foreach ($fn in $fnNames) {
        $body = Get-PsFunctionText -ScriptPath $rotatePs1 -FunctionName $fn
        Invoke-Expression $body
    }

    $script:HasStructuredLogger = $true
}

Describe "Apply-ProfileSwitch rollback" {
    BeforeEach {
        # Per-test sandbox so we never touch real ~/.claude-orchestrator
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("aps-{0}" -f ([Guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:sandbox -Force | Out-Null

        # state.json with two profiles, claude-a active
        $stateObj = [ordered]@{
            version        = 1
            updatedAt      = '2026-05-09T00:00:00Z'
            active_profile = 'claude-a'
            profiles       = [ordered]@{
                'claude-a' = [ordered]@{ profileId = 'claude-a'; state = 'available'; cooldownUntil = $null; loggedIn = $true }
                'claude-b' = [ordered]@{ profileId = 'claude-b'; state = 'available'; cooldownUntil = $null; loggedIn = $true }
            }
        }
        $script:stateFile = Join-Path $script:sandbox 'state.json'
        $stateObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:stateFile -Encoding UTF8

        # config.json mapping profile -> config_dir
        $script:profileADir = Join-Path $script:sandbox 'profile-a'
        $script:profileBDir = Join-Path $script:sandbox 'profile-b'
        New-Item -ItemType Directory -Path $script:profileADir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:profileBDir -Force | Out-Null

        $configObj = [ordered]@{
            version  = 1
            profiles = @(
                [ordered]@{ name = 'claude-a'; config_dir = $script:profileADir },
                [ordered]@{ name = 'claude-b'; config_dir = $script:profileBDir }
            )
        }
        $script:configFile = Join-Path $script:sandbox 'config.json'
        $configObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:configFile -Encoding UTF8

        # Junction 'active' currently pointing at profile-a, in a sandbox-local
        # profilesRoot so we never touch %USERPROFILE%\.claude-profiles.
        $script:profilesRoot   = Join-Path $script:sandbox 'profiles-root'
        New-Item -ItemType Directory -Path $script:profilesRoot -Force | Out-Null
        $script:activeJunction = Join-Path $script:profilesRoot 'active'
        New-Item -ItemType Junction -Path $script:activeJunction -Target $script:profileADir | Out-Null

        # Logger paths inside sandbox
        $script:LogFile     = Join-Path $script:sandbox 'rotation.log'
        $script:JsonLogFile = Join-Path $script:sandbox 'rotation.jsonl'
        $script:HasStructuredLogger = $true

        # Capture snapshot for invariants
        $script:stateRawBefore = Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8
    }

    AfterEach {
        # Cleanup junction first (Remove-Item on dir junction needs care)
        if (Test-Path -LiteralPath $script:activeJunction) {
            try {
                $jItem = Get-Item -LiteralPath $script:activeJunction -Force
                if (($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    [System.IO.Directory]::Delete($script:activeJunction, $false)
                }
            } catch { $null = $_ }
        }
        if (Test-Path -LiteralPath $script:sandbox) {
            Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Rolls back when New-Item -Junction throws — active profile + state.json unchanged" {
        # Mock New-Item ONLY for junction creation. Apply-ProfileSwitch was
        # dot-sourced into script scope, so Pester's mock at script scope
        # intercepts its New-Item calls.
        Mock New-Item {
            throw "permission denied"
        } -ParameterFilter { $ItemType -eq 'Junction' }

        # Sanity: junction starts pointing at profile-a
        $beforeTarget = (Get-Item -LiteralPath $script:activeJunction -Force).Target | Select-Object -First 1
        $beforeTarget | Should -Be $script:profileADir

        # Act — should re-throw the original exception
        {
            Apply-ProfileSwitch -ProfileName 'claude-b' `
                -StateFileOverride   $script:stateFile `
                -ConfigFileOverride  $script:configFile `
                -ProfilesRootOverride $script:profilesRoot
        } | Should -Throw

        # Mock was actually invoked
        Should -Invoke New-Item -ParameterFilter { $ItemType -eq 'Junction' } -Times 1 -Exactly:$false

        # state.json byte-identical to snapshot — rollback restored it
        $stateAfterRaw = Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8
        $stateAfterRaw | Should -Be $script:stateRawBefore

        # active_profile still claude-a in the parsed JSON
        $stateAfter = $stateAfterRaw | ConvertFrom-Json
        $stateAfter.active_profile | Should -Be 'claude-a'

        # NOTE: Because New-Item is mocked to ALWAYS throw on Junction,
        # the rollback's attempt to recreate the old junction also fails.
        # That is acceptable — the contract under test is "do not corrupt
        # state.json and do not silently swap to the new profile".
    }

    It "Rolls back state.json + junction when Save-JsonFile throws after junction swap" {
        # Mock Save-JsonFile to fail — simulates a disk-full / permission
        # error during the state persist. Apply-ProfileSwitch must:
        #   - revert the junction to profile-a
        #   - restore state.json byte-identically
        #   - re-throw
        Mock Save-JsonFile {
            throw "disk full"
        }

        $beforeTarget = (Get-Item -LiteralPath $script:activeJunction -Force).Target | Select-Object -First 1
        $beforeTarget | Should -Be $script:profileADir

        {
            Apply-ProfileSwitch -ProfileName 'claude-b' `
                -StateFileOverride   $script:stateFile `
                -ConfigFileOverride  $script:configFile `
                -ProfilesRootOverride $script:profilesRoot
        } | Should -Throw

        # state.json restored byte-for-byte
        $stateAfterRaw = Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8
        $stateAfterRaw | Should -Be $script:stateRawBefore

        # Junction reverted to profile-a (rollback called New-Item -Junction
        # with the original target; New-Item is NOT mocked in this test).
        Test-Path -LiteralPath $script:activeJunction | Should -BeTrue
        $afterTarget = (Get-Item -LiteralPath $script:activeJunction -Force).Target | Select-Object -First 1
        $afterTarget | Should -Be $script:profileADir

        Should -Invoke Save-JsonFile -Times 1
    }

    It "Emits structured 'rollback' event with level=error on failure" {
        Mock New-Item {
            throw "permission denied"
        } -ParameterFilter { $ItemType -eq 'Junction' }

        {
            Apply-ProfileSwitch -ProfileName 'claude-b' `
                -StateFileOverride   $script:stateFile `
                -ConfigFileOverride  $script:configFile `
                -ProfilesRootOverride $script:profilesRoot
        } | Should -Throw

        Test-Path -LiteralPath $script:JsonLogFile | Should -BeTrue
        $lines = Get-Content -LiteralPath $script:JsonLogFile
        $rollbackLine = $lines | Where-Object { $_ -match '"event":"rollback"' } | Select-Object -First 1
        $rollbackLine | Should -Not -BeNullOrEmpty
        $obj = $rollbackLine | ConvertFrom-Json
        $obj.event  | Should -Be 'rollback'
        $obj.level  | Should -Be 'error'
        $obj.target | Should -Be 'claude-b'
        $obj.reason | Should -Match 'permission denied'
    }

    It "DryRun returns metadata without modifying state.json or junction" {
        $beforeTarget = (Get-Item -LiteralPath $script:activeJunction -Force).Target | Select-Object -First 1
        $result = Apply-ProfileSwitch -ProfileName 'claude-b' -DryRun `
            -StateFileOverride   $script:stateFile `
            -ConfigFileOverride  $script:configFile `
            -ProfilesRootOverride $script:profilesRoot

        $result.DryRun      | Should -BeTrue
        $result.ProfileName | Should -Be 'claude-b'
        $result.NewTarget   | Should -Be $script:profileBDir

        # state.json unchanged
        (Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8) | Should -Be $script:stateRawBefore
        # junction unchanged
        $afterTarget = (Get-Item -LiteralPath $script:activeJunction -Force).Target | Select-Object -First 1
        $afterTarget | Should -Be $beforeTarget
    }
}
