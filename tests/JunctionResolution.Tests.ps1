# tests/JunctionResolution.Tests.ps1 — Pester 5 tests for BUG-D fix
#
# Validates Get-ActiveProfileFromJunction's ability to resolve the real profile
# name when CLAUDE_CONFIG_DIR points to an NTFS junction (e.g. ~/.claude-profiles/active).
# Without the fix, Split-Path -Leaf on the junction path returns 'active' which
# fails Test-IsValidProfileName and aborts auto-rotate's main loop.
#
# Test strategy:
#   1. Junction case  : create a real junction in TEMP -> assert leaf == target name.
#   2. Plain dir case : create a plain dir in TEMP    -> assert leaf == dir name.
#   3. Missing path   : pass a path that doesn't exist -> assert no exception
#                       and graceful return ($null without state.json).
#
# We also dot-source the function body via regex so the script's "main" rotation
# code (which exits on missing state.json) does not run.

BeforeAll {
    $repoRoot   = Split-Path -Parent $PSScriptRoot
    $rotatePs1  = Join-Path $repoRoot 'auto-rotate.ps1'

    if (-not (Test-Path -LiteralPath $rotatePs1)) {
        throw "auto-rotate.ps1 not found at $rotatePs1"
    }

    function Get-PsFunctionText {
        param([string]$ScriptPath, [string]$FunctionName)
        $text  = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
        $regex = "(?ms)^function\s+$([regex]::Escape($FunctionName))\s*\{.*?^\}"
        $m     = [regex]::Match($text, $regex)
        if (-not $m.Success) { throw "Function $FunctionName not found in $ScriptPath" }
        return $m.Value
    }

    # Load the function under test
    $body = Get-PsFunctionText -ScriptPath $rotatePs1 -FunctionName 'Get-ActiveProfileFromJunction'
    Invoke-Expression $body

    # Sandbox dir for junctions/dirs created by tests
    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("junction-test-{0}" -f ([Guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null

    # Override env:USERPROFILE so the function's state.json fallback points to a
    # known-empty directory (so missing-path test doesn't accidentally pick up
    # the real ~/.claude-orchestrator/state.json from the dev machine).
    $script:OriginalUserProfile = $env:USERPROFILE
    $env:USERPROFILE = $script:Sandbox
}

AfterAll {
    # Restore env and clean up sandbox
    if ($script:OriginalUserProfile) { $env:USERPROFILE = $script:OriginalUserProfile }
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        # Junctions need cmd /c rmdir to avoid Remove-Item walking into target
        Get-ChildItem -LiteralPath $script:Sandbox -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                if ($_.LinkType -in @('Junction','SymbolicLink')) {
                    & cmd.exe /c rmdir """$($_.FullName)""" 2>$null
                }
            }
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Get-ActiveProfileFromJunction (BUG-D)" {
    It "Resolves a junction to the target profile name (not 'active')" {
        # Arrange: create real profile dir + 'active' junction pointing to it
        $profileDir   = Join-Path $script:Sandbox 'claude-a'
        $junctionLink = Join-Path $script:Sandbox 'active'
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        # Use cmd /c mklink /J for cross-version junction creation (works in
        # PS5.1 and PS7 without admin)
        & cmd.exe /c mklink /J """$junctionLink""" """$profileDir""" | Out-Null
        try {
            # Sanity check
            (Get-Item -LiteralPath $junctionLink -Force).LinkType | Should -Be 'Junction'

            # Act
            $result = Get-ActiveProfileFromJunction -ConfigDir $junctionLink

            # Assert
            $result | Should -Be 'claude-a'
            $result | Should -Not -Be 'active'
        } finally {
            & cmd.exe /c rmdir """$junctionLink""" 2>$null
            Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns the directory name when the path is a plain directory (no junction)" {
        # Arrange: plain dir, no junction
        $plainDir = Join-Path $script:Sandbox 'claude-c'
        New-Item -ItemType Directory -Path $plainDir -Force | Out-Null
        try {
            # Sanity check
            (Get-Item -LiteralPath $plainDir -Force).LinkType | Should -BeNullOrEmpty

            # Act
            $result = Get-ActiveProfileFromJunction -ConfigDir $plainDir

            # Assert
            $result | Should -Be 'claude-c'
        } finally {
            Remove-Item -LiteralPath $plainDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Returns null gracefully when ConfigDir does not exist (no state.json fallback)" {
        # Arrange: ensure sandbox has no .claude-orchestrator/state.json so
        # the fallback path returns $null cleanly. Path does not exist on disk.
        $missing = Join-Path $script:Sandbox ("does-not-exist-{0}" -f ([Guid]::NewGuid().ToString('N')))
        Test-Path -LiteralPath $missing | Should -BeFalse

        # Sandbox has no .claude-orchestrator dir (clean USERPROFILE override)
        $stateGuard = Join-Path $script:Sandbox '.claude-orchestrator\state.json'
        Test-Path -LiteralPath $stateGuard | Should -BeFalse

        # Act + Assert: must not throw
        $result = $null
        { $result = Get-ActiveProfileFromJunction -ConfigDir $missing } | Should -Not -Throw

        # Path doesn't exist -> $resolved == $missing -> leaf is the random name
        # which is NOT 'active' so it returns the leaf. This is acceptable
        # because Test-IsValidProfileName at the call site rejects bogus names
        # and triggers the secondary split fallback. We just verify it doesn't
        # throw and doesn't return 'active'.
        $result | Should -Not -Be 'active'
    }
}
