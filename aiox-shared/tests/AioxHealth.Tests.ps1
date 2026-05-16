# aiox-shared/tests/AioxHealth.Tests.ps1
# Hardening #3: cmdlet `aiohealth` (Test-AioxHealth) — testes Pester 5.
#
# Estrategia: usar -Sequential para que todos os checks rodem no runspace
# atual (Start-Job nao consegue ver Mocks). Em seguida mockamos cada
# Test-AioxCheck-* dentro do ModuleName 'Health' para controlar resultados.
#
# Nota sobre Pester 5 mock scope: mocks definidos em BeforeEach as vezes
# vazam para Contexts subsequentes dependendo de como Pester resolve o
# escopo dos parametros default. Para evitar flakiness, cada It cria
# explicitamente todos os 10 mocks que precisa (sem usar BeforeEach mocks).

BeforeAll {
    $script:ModulePath = (Resolve-Path "$PSScriptRoot/../Health.psm1").Path
    Import-Module $script:ModulePath -Force
}

Describe "Test-AioxHealth" {

    Context "structure of return value (all checks OK)" {

        It "Quiet returns `$true when all checks are ok" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok'; detail = '' } }

            $r = Test-AioxHealth -Quiet -Sequential 6>$null
            $r | Should -BeTrue
        }

        It "non-Quiet returns hashtable with overall, checks, totalDurationMs" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok'; detail = '' } }

            $r = Test-AioxHealth -Sequential 6>$null
            $r | Should -BeOfType [hashtable]
            $r.ContainsKey('overall')         | Should -BeTrue
            $r.ContainsKey('checks')          | Should -BeTrue
            $r.ContainsKey('totalDurationMs') | Should -BeTrue
            $r.overall                        | Should -Be 'ok'
            $r.totalDurationMs                | Should -BeGreaterOrEqual 0
        }

        It "each check has name, status, detail, durationMs" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok'; detail = '' } }

            $r = Test-AioxHealth -Sequential 6>$null
            foreach ($c in $r.checks) {
                $c.ContainsKey('name')       | Should -BeTrue
                $c.ContainsKey('status')     | Should -BeTrue
                $c.ContainsKey('detail')     | Should -BeTrue
                $c.ContainsKey('durationMs') | Should -BeTrue
                $c.status                    | Should -BeIn @('ok','warn','error')
                $c.durationMs                | Should -BeGreaterOrEqual 0
            }
        }

        It "SkipSsh excludes vps-ssh-reach check" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok'; detail = '' } }

            $r = Test-AioxHealth -SkipSsh -Sequential 6>$null
            ($r.checks | Where-Object { $_.name -eq 'vps-ssh-reach' }) | Should -BeNullOrEmpty
            $r.checks.Count | Should -Be 9
        }

        It "all 10 checks run when SkipSsh is NOT passed" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok'; detail = '' } }

            $r = Test-AioxHealth -Sequential 6>$null
            $r.checks.Count | Should -Be 10
            $names = $r.checks | ForEach-Object { $_.name }
            $names | Should -Contain 'vps-ssh-reach'
        }

        It "total duration is reasonable in mocked environment (< 3000ms)" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok'; detail = '' } }

            $r = Test-AioxHealth -Sequential 6>$null
            $r.totalDurationMs | Should -BeLessThan 3000
        }
    }

    Context "overall aggregation" {

        It "overall='warn' when at least one warn and zero errors" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'warn'; detail = 'old entry' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok';   detail = '' } }

            $r = Test-AioxHealth -Sequential 6>$null
            $r.overall | Should -Be 'warn'
            @($r.checks | Where-Object status -eq 'warn').Count  | Should -Be 1
            @($r.checks | Where-Object status -eq 'error').Count | Should -Be 0
        }

        It "overall='error' when at least one error" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'error'; detail = '3 failed' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'warn';  detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok';    detail = '' } }

            $r = Test-AioxHealth -Sequential 6>$null
            $r.overall | Should -Be 'error'
            @($r.checks | Where-Object status -eq 'error').Count | Should -BeGreaterOrEqual 1
        }

        It "Quiet returns `$false when there is at least one error" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok';    detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'error'; detail = '0.3 GB free' } }

            $r = Test-AioxHealth -Quiet -Sequential 6>$null
            $r | Should -BeFalse
        }

        It "Quiet returns `$false when only warns (overall != ok)" {
            # Spec: Quiet retorna $true se overall='ok', $false caso contrario.
            # Warn nao e ok, entao tem que dar false.
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { @{ status = 'warn'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok';   detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok';   detail = '' } }

            $r = Test-AioxHealth -Quiet -Sequential 6>$null
            $r | Should -BeFalse
        }
    }

    Context "exception handling in checks" {

        It "wraps a throwing check as status='error' (does not crash)" {
            Mock -ModuleName Health Test-AioxCheck-PwshSyntax         { throw 'boom' }
            Mock -ModuleName Health Test-AioxCheck-PesterQuick        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ScheduledTasks     { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ReconcileRecent    { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSyncStatus      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-OauthRefreshJsonl  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-RotationJsonlSize  { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-ActiveProfile      { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-VpsSshReach        { @{ status = 'ok'; detail = '' } }
            Mock -ModuleName Health Test-AioxCheck-DiskFree           { @{ status = 'ok'; detail = '' } }

            $r = Test-AioxHealth -Sequential 6>$null
            $syntaxCheck = $r.checks | Where-Object name -eq 'pwsh-syntax'
            $syntaxCheck.status | Should -Be 'error'
            $syntaxCheck.detail | Should -Match 'exception'
            $r.overall | Should -Be 'error'
        }
    }
}
