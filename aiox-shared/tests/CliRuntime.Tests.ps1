# aiox-shared/tests/CliRuntime.Tests.ps1
# Plano: docs/superpowers/plans/2026-05-10-evolution-d.md  Task 7
#
# Cobre o contrato de Get-CliProfile + Invoke-CliRotation para os 4 CliTypes
# suportados (claude, codex, gemini). Os testes nao tocam HKCU
# nem ~/.<cli>-profiles real — todos usam UserProfileOverride com TestDrive.

BeforeAll {
    $script:ModulePath = (Resolve-Path "$PSScriptRoot/../CliRuntime.psm1").Path
    Import-Module $script:ModulePath -Force
}

Describe "Get-CliProfile contract" {

    BeforeEach {
        $script:fakeHome = Join-Path $TestDrive "home-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:fakeHome -Force | Out-Null
    }

    It "claude returns junction SwapMethod with .credentials.json + JunctionPath + EnvVarName" {
        $profileDir = Join-Path $script:fakeHome ".claude-profiles\claude-a"
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

        $p = Get-CliProfile -CliType 'claude' -ProfileName 'claude-a' -UserProfileOverride $script:fakeHome

        $p.CliType      | Should -Be 'claude'
        $p.ProfileName  | Should -Be 'claude-a'
        $p.SwapMethod   | Should -Be 'junction'
        $p.AuthFile     | Should -Be '.credentials.json'
        $p.ConfigDir    | Should -Be $profileDir
        $p.JunctionPath | Should -Be (Join-Path $script:fakeHome ".claude-profiles\active")
        $p.EnvVarName   | Should -Be 'CLAUDE_CONFIG_DIR'
        $p.Exists       | Should -BeTrue
    }

    It "codex returns copy SwapMethod with auth.json + TargetDir" {
        $profileDir = Join-Path $script:fakeHome ".codex-profiles\codex-a"
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

        $p = Get-CliProfile -CliType 'codex' -ProfileName 'codex-a' -UserProfileOverride $script:fakeHome

        $p.SwapMethod | Should -Be 'copy'
        $p.AuthFile   | Should -Be 'auth.json'
        $p.ConfigDir  | Should -Be $profileDir
        $p.TargetDir  | Should -Be (Join-Path $script:fakeHome ".codex")
        $p.EnvVarName | Should -Be 'CODEX_HOME'
        $p.PSObject.Properties.Name | Should -Not -Contain 'JunctionPath'
    }

    It "gemini returns env SwapMethod with oauth_creds.json + GEMINI_CONFIG_DIR" {
        # Pasta NAO criada de proposito — Get-CliProfile deve devolver Exists=$false
        # sem explodir. Quem decide se aborta e o caller (Invoke-CliRotation).
        $p = Get-CliProfile -CliType 'gemini' -ProfileName 'g1' -UserProfileOverride $script:fakeHome

        $p.SwapMethod | Should -Be 'env'
        $p.AuthFile   | Should -Be 'oauth_creds.json'
        $p.ConfigDir  | Should -Be (Join-Path $script:fakeHome ".gemini-profiles\g1")
        $p.EnvVarName | Should -Be 'GEMINI_CONFIG_DIR'
        $p.Exists     | Should -BeFalse
        $p.PSObject.Properties.Name | Should -Not -Contain 'JunctionPath'
        $p.PSObject.Properties.Name | Should -Not -Contain 'TargetDir'
    }

    It "rejects qwen as invalid CliType (removed in 2026-05-10)" {
        { Get-CliProfile -CliType 'qwen' -ProfileName 'q1' -UserProfileOverride $script:fakeHome } |
            Should -Throw
    }

    It "rejects invalid CliType via ValidateSet" {
        { Get-CliProfile -CliType 'bogus' -ProfileName 'x' -UserProfileOverride $script:fakeHome } |
            Should -Throw
    }
}

Describe "Invoke-CliRotation routing" {

    BeforeEach {
        $script:fakeHome = Join-Path $TestDrive "home-rot-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:fakeHome -Force | Out-Null
    }

    It "from==to is a noop (does not touch FS)" {
        $r = Invoke-CliRotation -CliType 'gemini' -FromProfile 'g1' -ToProfile 'g1' `
                                -UserProfileOverride $script:fakeHome -DryRun
        $r.Action | Should -Be 'noop'
        $r.Reason | Should -Be 'from-equals-to'
    }

    It "throws helpful error if target profile dir does not exist (gemini)" {
        # SwapMethod='env' sem -DryRun deve abortar antes de mexer em env vars.
        { Invoke-CliRotation -CliType 'gemini' -FromProfile 'g1' -ToProfile 'g2' `
                             -UserProfileOverride $script:fakeHome } |
            Should -Throw -ExpectedMessage '*pasta de perfil nao existe*'
    }

    It "DryRun for env CLI returns intent without setting env var" {
        $profileDir = Join-Path $script:fakeHome ".gemini-profiles\g2"
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

        $r = Invoke-CliRotation -CliType 'gemini' -FromProfile 'g1' -ToProfile 'g2' `
                                -UserProfileOverride $script:fakeHome -DryRun
        $r.Action     | Should -Be 'env-set'
        $r.DryRun     | Should -BeTrue
        $r.EnvVarName | Should -Be 'GEMINI_CONFIG_DIR'
        $r.ConfigDir  | Should -Be $profileDir
    }

    It "DryRun for copy CLI checks source auth file exists" {
        $profileDir = Join-Path $script:fakeHome ".codex-profiles\codex-b"
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        # Sem auth.json criado: deve falhar com mensagem clara
        { Invoke-CliRotation -CliType 'codex' -FromProfile 'codex-a' -ToProfile 'codex-b' `
                             -UserProfileOverride $script:fakeHome -DryRun } |
            Should -Throw -ExpectedMessage '*arquivo de auth ausente*'

        # Com auth.json criado: DryRun retorna intent sem copiar
        Set-Content -LiteralPath (Join-Path $profileDir 'auth.json') -Value '{"k":"v"}' -Encoding UTF8
        $r = Invoke-CliRotation -CliType 'codex' -FromProfile 'codex-a' -ToProfile 'codex-b' `
                                -UserProfileOverride $script:fakeHome -DryRun
        $r.Action      | Should -Be 'auth-copy'
        $r.DryRun      | Should -BeTrue
        $r.Source      | Should -Be (Join-Path $profileDir 'auth.json')
        $r.Destination | Should -Be (Join-Path $script:fakeHome ".codex\auth.json")
        # destino NAO foi criado
        Test-Path -LiteralPath $r.Destination | Should -BeFalse
    }
}

Describe "Swap-ViaEnvVar with Process scope" {

    BeforeEach {
        $script:fakeHome = Join-Path $TestDrive "home-env-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:fakeHome -Force | Out-Null
    }

    It "applies env var with -Scope Process so test does not leak to HKCU" {
        $profileDir = Join-Path $script:fakeHome ".gemini-profiles\g-test"
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null

        $before = $env:GEMINI_CONFIG_DIR
        try {
            $r = Swap-ViaEnvVar -CliType 'gemini' -ToProfile 'g-test' `
                                -UserProfileOverride $script:fakeHome -Scope Process
            $r.Action | Should -Be 'env-set'
            $r.DryRun | Should -BeFalse
            # Process-scope env var deve estar visivel imediatamente
            $env:GEMINI_CONFIG_DIR | Should -Be $profileDir
        } finally {
            # Cleanup: restaurar Process-scope
            [System.Environment]::SetEnvironmentVariable('GEMINI_CONFIG_DIR', $before, 'Process')
        }
    }
}
