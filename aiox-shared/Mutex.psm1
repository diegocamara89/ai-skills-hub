# aiox-shared/Mutex.psm1 — Cross-process mutex helper backed by [System.Threading.Mutex]
# Used by auto-rotate*.ps1 to serialize junction swaps across concurrent invocations
# (e.g., Task Scheduler + manual run).
#
# Mutex name uses the "Global\" prefix so the lock spans all logon sessions of the
# same Windows user. On Windows the "Global\" namespace is machine-wide, but
# accessing it from a non-elevated user-session still works for objects created
# by the same user; Local\ would be terminal-services-session-scoped which is too
# narrow when the user runs both a normal shell and an elevated one. If we ever
# need cross-user (LocalSystem ↔ user) locking, callers must pre-create a DACL'd
# mutex — out of scope here.
#
# WaitOne returns $false on timeout. We translate that into [System.TimeoutException]
# so callers can use a single try/catch instead of inspecting return values.

Set-StrictMode -Version Latest

function Acquire-FileLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Timeout = 30
    )

    $mutexName = "Global\aiox-$Name"
    # createdNew is required by the constructor signature with initiallyOwned=$false;
    # we don't use it but keep the variable for clarity.
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)

    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($Timeout))
    } catch [System.Threading.AbandonedMutexException] {
        # Previous owner died without releasing. WaitOne already transferred
        # ownership to us, so treat as acquired and proceed.
        $acquired = $true
    }

    if (-not $acquired) {
        $mutex.Dispose()
        throw [System.TimeoutException]::new("Could not acquire lock '$Name' within ${Timeout}s")
    }

    return $mutex
}

function Release-FileLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Handle)

    if ($null -eq $Handle) { return }

    try {
        $Handle.ReleaseMutex()
    } catch {
        # ReleaseMutex throws ApplicationException if current thread doesn't own
        # the mutex (e.g. Acquire failed and Handle is stale, or release-twice).
        # Swallow — Dispose below still cleans up the OS handle.
        $null = $_
    }

    try { $Handle.Dispose() } catch { $null = $_ }
}

Export-ModuleMember -Function Acquire-FileLock, Release-FileLock
