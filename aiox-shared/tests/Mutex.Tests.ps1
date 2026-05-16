# aiox-shared/tests/Mutex.Tests.ps1
# Pester 5 tests for Acquire-FileLock / Release-FileLock.

BeforeAll {
    $script:ModulePath = (Resolve-Path "$PSScriptRoot/../Mutex.psm1").Path
    Import-Module $script:ModulePath -Force
}

Describe "Acquire-FileLock" {

    It "Blocks second acquirer until first releases" {
        $lockName = "test-block-$(Get-Random)"
        $modulePath = $script:ModulePath

        # Background job: acquire, hold for ~2s, release.
        $job1 = Start-Job -ScriptBlock {
            param($mp, $n)
            Import-Module $mp -Force
            $h = Acquire-FileLock -Name $n -Timeout 5
            Start-Sleep -Seconds 2
            Release-FileLock -Handle $h
            'job1-done'
        } -ArgumentList $modulePath, $lockName

        # Give the job a head start so it definitely owns the mutex.
        Start-Sleep -Milliseconds 500

        $start = Get-Date
        $h2 = Acquire-FileLock -Name $lockName -Timeout 10
        $elapsed = (Get-Date) - $start
        Release-FileLock -Handle $h2

        # We waited at least ~1.0s (job had ~1.5s of hold time left when we tried).
        $elapsed.TotalSeconds | Should -BeGreaterThan 1.0

        Wait-Job $job1 | Out-Null
        Receive-Job $job1 | Out-Null
        Remove-Job $job1 -Force
    }

    It "Throws TimeoutException if cannot acquire in -Timeout seconds" {
        # Mutex is reentrant on the owning thread, so we must hold the lock from
        # a separate runspace (background job) for this assertion to be meaningful.
        $lockName = "test-timeout-$(Get-Random)"
        $modulePath = $script:ModulePath

        $holder = Start-Job -ScriptBlock {
            param($mp, $n)
            Import-Module $mp -Force
            $h = Acquire-FileLock -Name $n -Timeout 5
            # Hold long enough for the foreground attempt to time out.
            Start-Sleep -Seconds 4
            Release-FileLock -Handle $h
        } -ArgumentList $modulePath, $lockName

        # Let the job grab the mutex.
        Start-Sleep -Milliseconds 500

        try {
            { Acquire-FileLock -Name $lockName -Timeout 1 } |
                Should -Throw -ExceptionType ([System.TimeoutException])
        } finally {
            Wait-Job $holder | Out-Null
            Receive-Job $holder | Out-Null
            Remove-Job $holder -Force
        }
    }
}
