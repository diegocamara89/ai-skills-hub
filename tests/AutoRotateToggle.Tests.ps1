#Requires -Version 7.0
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# Pester 5 tests for the auto-rotate toggle feature (Task 1).
# Validates that:
#   - autoRotateEnabled defaults to $false on a fresh config
#   - autoRotateEnabled persists when saved/reloaded
#   - The field is back-filled if missing on existing configs

BeforeAll {
    # Dot-source manage-skills.ps1 to import all helper functions.
    # Default $Command = "help" just runs Show-Help which prints text to host
    # and is otherwise side-effect free. We swallow that output so test
    # reports stay clean.
    $script:HubRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:scriptPath = Join-Path $script:HubRoot "manage-skills.ps1"
    . $script:scriptPath *>$null
}

Describe "Auto-rotate toggle config" {

    BeforeEach {
        # Each test runs against an isolated temp dir so we never touch the
        # user's real ~/.claude-orchestrator/config.json.
        $script:tmpDir = Join-Path $env:TEMP ("aiox-test-" + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $script:tmpConfig = Join-Path $script:tmpDir "config.json"
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:tmpDir) {
            Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "Defaults autoRotateEnabled to false when config is fresh" {
        $config = Ensure-ClaudeOrchestratorConfig -ConfigPath $script:tmpConfig
        $config | Should -Not -BeNullOrEmpty
        $config.PSObject.Properties.Name | Should -Contain 'autoRotateEnabled'
        [bool]$config.autoRotateEnabled | Should -Be $false
    }

    It "Persists autoRotateEnabled=true after Save-ClaudeOrchestratorConfig" {
        $config = Ensure-ClaudeOrchestratorConfig -ConfigPath $script:tmpConfig
        $config.autoRotateEnabled = $true
        Save-ClaudeOrchestratorConfig -Config $config -ConfigPath $script:tmpConfig

        $reloaded = Get-ClaudeOrchestratorConfig -ConfigPath $script:tmpConfig
        $reloaded | Should -Not -BeNullOrEmpty
        [bool]$reloaded.autoRotateEnabled | Should -Be $true
    }

    It "Back-fills autoRotateEnabled=false on legacy configs that lack the field" {
        # Simulate a pre-existing config missing the new field
        $legacy = [ordered]@{
            version = 1
            profiles = @()
        }
        $json = $legacy | ConvertTo-Json -Depth 6
        Set-Content -LiteralPath $script:tmpConfig -Value $json -Encoding UTF8

        $config = Ensure-ClaudeOrchestratorConfig -ConfigPath $script:tmpConfig
        $config.PSObject.Properties.Name | Should -Contain 'autoRotateEnabled'
        [bool]$config.autoRotateEnabled | Should -Be $false
    }
}
