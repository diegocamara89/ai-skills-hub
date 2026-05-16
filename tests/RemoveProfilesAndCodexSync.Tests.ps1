#Requires -Version 7.0
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

# tests/RemoveProfilesAndCodexSync.Tests.ps1
#
# Cobre:
#   - Remove-ClaudeProfile: rejeita perfil inexistente, ativo ou ultimo;
#     soft-delete OK movendo a pasta para ~/.claude-profiles-removed/<name>-<ts>.
#   - Remove-GeminiProfile: rejeita inexistente; soft-delete OK.
#   - Invoke-VpsAuthSyncForCodex: skip se profileDir/auth.json ausentes;
#     chama o Python com --codex-source <path/auth.json>; retorna estrutura
#     com pushCodex/applied quando o JSON do stdout indica sucesso.
#
# Toda I/O usa TestDrive. Nao tocamos perfis Claude/Gemini reais.
# A invocacao do Python e mockada via Mock Invoke-VpsAuthSyncProcess para
# nao depender do interpretador real nem do script vps_ai_auth_sync.py.

BeforeAll {
    . "$PSScriptRoot/../manage-skills.ps1" 2>$null
}

Describe "Remove-ClaudeProfile" {
    BeforeEach {
        $script:profilesRoot = Join-Path $TestDrive ('claude-profiles-' + [guid]::NewGuid())
        $script:backupRoot   = Join-Path $TestDrive ('claude-profiles-removed-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:profilesRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:profilesRoot 'claude-a') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:profilesRoot 'claude-b') -Force | Out-Null

        Mock Get-ActiveClaudeProfileName { 'claude-a' }
        Mock Ensure-ClaudeOrchestratorConfig {
            return [pscustomobject]@{
                profiles = @(
                    [pscustomobject]@{ name = 'claude-a'; config_dir = (Join-Path $script:profilesRoot 'claude-a') },
                    [pscustomobject]@{ name = 'claude-b'; config_dir = (Join-Path $script:profilesRoot 'claude-b') }
                )
            }
        }
        Mock Save-ClaudeOrchestratorConfig { } -ParameterFilter { $true }
        Mock Get-ClaudeAccountStateStore {
            return @{
                profiles = ([ordered]@{
                    'claude-a' = @{ profileId = 'claude-a' }
                    'claude-b' = @{ profileId = 'claude-b' }
                })
            }
        }
        Mock Save-ClaudeAccountStateStore { } -ParameterFilter { $true }
    }

    It "Throws if the profile directory does not exist" {
        { Remove-ClaudeProfile -Name 'claude-z' -ProfilesRoot $script:profilesRoot -BackupRoot $script:backupRoot } |
            Should -Throw -ExpectedMessage '*claude-z*'
    }

    It "Throws when removing the active profile" {
        { Remove-ClaudeProfile -Name 'claude-a' -ProfilesRoot $script:profilesRoot -BackupRoot $script:backupRoot } |
            Should -Throw -ExpectedMessage '*perfil ativo*'
    }

    It "Throws when only one profile remains" {
        Mock Ensure-ClaudeOrchestratorConfig {
            return [pscustomobject]@{
                profiles = @(
                    [pscustomobject]@{ name = 'claude-b'; config_dir = (Join-Path $script:profilesRoot 'claude-b') }
                )
            }
        }
        # Active != claude-b so the "active" guard does not short-circuit.
        Mock Get-ActiveClaudeProfileName { $null }
        { Remove-ClaudeProfile -Name 'claude-b' -ProfilesRoot $script:profilesRoot -BackupRoot $script:backupRoot } |
            Should -Throw -ExpectedMessage '*ultimo perfil*'
    }

    It "Moves the profile dir into a timestamped backup folder" {
        $r = Remove-ClaudeProfile -Name 'claude-b' -ProfilesRoot $script:profilesRoot -BackupRoot $script:backupRoot
        $r.removed | Should -BeTrue
        $r.name    | Should -Be 'claude-b'
        Test-Path -LiteralPath (Join-Path $script:profilesRoot 'claude-b') | Should -BeFalse
        Test-Path -LiteralPath $r.backupDir -PathType Container | Should -BeTrue
        # Backup folder name must start with the profile name and contain a timestamp suffix.
        (Split-Path -Leaf $r.backupDir) | Should -Match '^claude-b-\d{8}-\d{6}$'
        Split-Path -Parent $r.backupDir | Should -Be $script:backupRoot
    }
}

Describe "Remove-GeminiProfile" {
    BeforeEach {
        $script:gemRoot   = Join-Path $TestDrive ('gemini-profiles-' + [guid]::NewGuid())
        $script:gemBackup = Join-Path $TestDrive ('gemini-profiles-removed-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:gemRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:gemRoot 'gemini-a') -Force | Out-Null
    }

    It "Throws when the profile does not exist" {
        { Remove-GeminiProfile -Name 'gemini-zz' -ProfilesRoot $script:gemRoot -BackupRoot $script:gemBackup } |
            Should -Throw -ExpectedMessage '*gemini-zz*'
    }

    It "Soft-deletes the profile into the backup root" {
        $r = Remove-GeminiProfile -Name 'gemini-a' -ProfilesRoot $script:gemRoot -BackupRoot $script:gemBackup
        $r.removed | Should -BeTrue
        $r.name    | Should -Be 'gemini-a'
        Test-Path -LiteralPath (Join-Path $script:gemRoot 'gemini-a') | Should -BeFalse
        Test-Path -LiteralPath $r.backupDir -PathType Container | Should -BeTrue
        (Split-Path -Leaf $r.backupDir) | Should -Match '^gemini-a-\d{8}-\d{6}$'
        Split-Path -Parent $r.backupDir | Should -Be $script:gemBackup
    }
}

Describe "Invoke-VpsAuthSyncForCodex" {
    BeforeEach {
        $script:codexRoot = Join-Path $TestDrive ('codex-profiles-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:codexRoot -Force | Out-Null

        # Faz Update-VpsAuthSyncStatus virar no-op para evitar tocar arquivos reais.
        Mock Update-VpsAuthSyncStatus { } -ParameterFilter { $true }

        # Defaults para script-level state (testes individuais sobrescrevem se preciso).
        $script:fakeSyncScript = Join-Path $TestDrive 'fake_sync_script.py'
        Set-Content -LiteralPath $script:fakeSyncScript -Value '# fake' -Encoding UTF8
        $Script:VpsAuthSyncScriptPath = $script:fakeSyncScript

        # Resolve-PythonExe sempre retorna um path fake para nao depender da maquina.
        Mock Resolve-PythonExe { 'C:\fake\python.exe' }
    }

    It "Skips with profile_dir_not_found when the profile folder is missing" {
        Mock Invoke-VpsAuthSyncProcess { throw "nao deveria ser invocado" }
        $r = Invoke-VpsAuthSyncForCodex -ProfileName 'codex-z' -ProfilesRoot $script:codexRoot
        [string]$r.status | Should -Be 'skip'
        [string]$r.reason | Should -Be 'profile_dir_not_found'
        Should -Invoke Invoke-VpsAuthSyncProcess -Times 0 -Exactly
    }

    It "Skips with no_auth_json when auth.json is missing" {
        New-Item -ItemType Directory -Path (Join-Path $script:codexRoot 'codex-a') -Force | Out-Null
        Mock Invoke-VpsAuthSyncProcess { throw "nao deveria ser invocado" }
        $r = Invoke-VpsAuthSyncForCodex -ProfileName 'codex-a' -ProfilesRoot $script:codexRoot
        [string]$r.status | Should -Be 'skip'
        [string]$r.reason | Should -Be 'no_auth_json'
        Should -Invoke Invoke-VpsAuthSyncProcess -Times 0 -Exactly
    }

    It "Invokes Python with --codex-source pointing to auth.json (not the profile folder)" {
        $pd = Join-Path $script:codexRoot 'codex-a'
        New-Item -ItemType Directory -Path $pd -Force | Out-Null
        $aj = Join-Path $pd 'auth.json'
        Set-Content -LiteralPath $aj -Value '{"tokens":{"refresh_token":"x"}}' -Encoding UTF8

        $script:capturedArgs = $null
        Mock Invoke-VpsAuthSyncProcess {
            param($PythonExe, $Arguments, $TimeoutMs)
            $script:capturedArgs = $Arguments
            return [pscustomobject]@{
                ExitCode        = 0
                Stdout          = '{"status":"ok","push_codex":true,"push_claude":false,"applied":true}'
                Stderr          = ""
                TimedOut        = $false
                InvocationError = $null
            }
        }

        $r = Invoke-VpsAuthSyncForCodex -ProfileName 'codex-a' -ProfilesRoot $script:codexRoot
        Should -Invoke Invoke-VpsAuthSyncProcess -Times 1 -Exactly
        $captured = [string]$script:capturedArgs
        $captured                | Should -Not -BeNullOrEmpty
        ($captured -match '--apply')                                                | Should -BeTrue
        ($captured -match '--json')                                                 | Should -BeTrue
        ($captured -match '--codex-source')                                         | Should -BeTrue
        # The --codex-source argument must point to auth.json, not the profile folder.
        ($captured -like ('*' + $aj + '*'))                                         | Should -BeTrue
    }

    It "Parses pushCodex / applied / status from the JSON stdout line" {
        $profileDir = Join-Path $script:codexRoot 'codex-a'
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profileDir 'auth.json') -Value '{}' -Encoding UTF8

        Mock Invoke-VpsAuthSyncProcess {
            return [pscustomobject]@{
                ExitCode        = 0
                Stdout          = "garbage line`n{`"status`":`"ok`",`"push_codex`":true,`"applied`":true}`n"
                Stderr          = ""
                TimedOut        = $false
                InvocationError = $null
            }
        }

        $r = Invoke-VpsAuthSyncForCodex -ProfileName 'codex-a' -ProfilesRoot $script:codexRoot
        [string]$r.status      | Should -Be 'ok'
        [bool]$r.pushCodex     | Should -BeTrue
        [bool]$r.applied       | Should -BeTrue
        [int]$r.exitCode       | Should -Be 0
        [string]$r.codexSource | Should -Match 'auth\.json$'
    }

    It "Returns error on timeout" {
        $profileDir = Join-Path $script:codexRoot 'codex-a'
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profileDir 'auth.json') -Value '{}' -Encoding UTF8

        Mock Invoke-VpsAuthSyncProcess {
            return [pscustomobject]@{
                ExitCode        = -1
                Stdout          = ""
                Stderr          = ""
                TimedOut        = $true
                InvocationError = $null
            }
        }

        $r = Invoke-VpsAuthSyncForCodex -ProfileName 'codex-a' -ProfilesRoot $script:codexRoot
        [string]$r.status | Should -Be 'error'
        [string]$r.reason | Should -Be 'timeout_60s'
    }
}
