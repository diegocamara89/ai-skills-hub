# lib/oauth-refresh.ps1 - OAuth token auto-refresh (port of teamclaude approach).
#
# Plan: docs/superpowers/plans/2026-05-10-evolution-d.md  Task 8
#
# Responsibility:
#   Inspect a CLI profile's OAuth credentials (claude or codex), compute how many
#   seconds remain until access-token expiry, and trigger a refresh if the buffer
#   has dropped below the threshold (default 300s = 5 min).
#
# Why threshold = 300:
#   teamclaude's reference implementation refreshes 5 min before expiry. That gives
#   us enough headroom to retry once (with backoff) without ever serving an expired
#   token to a CLI invocation.
#
# Retry strategy:
#   3 attempts with exponential backoff (1s, 2s, 4s). Total worst-case 7s of sleep
#   plus the network calls themselves. Failure after 3 attempts is logged as
#   'oauth-refresh-fail' and the function returns $false so the caller can decide
#   what to do (e.g. mark the profile as auth_required).
#
# Logging:
#   All events go to ~/.claude-orchestrator/usage/logs/oauth-refresh.jsonl via
#   Write-StructuredLog (separate file from rotation.jsonl so refresh churn does
#   not pollute rotation analysis).
#
#   Events:
#     oauth-refresh-skip     -> token still valid (>=300s), nothing to do
#     oauth-refresh-attempt  -> about to call the refresh helper, attempt N of 3
#     oauth-refresh-success  -> refresh succeeded, new expiresIn
#     oauth-refresh-fail     -> exhausted retries, last error
#
# IMPORTANT - CLI refresh support (as of 2026-05-10):
#   The Claude CLI does NOT expose an explicit `claude auth refresh` subcommand.
#   `claude auth` only has login / logout / status. Tokens refresh implicitly when
#   the CLI hits the API with a stale token.
#   The Codex CLI has `codex login` which creates a fresh auth.json but is also
#   not a non-interactive `refresh` operation.
#
#   Until either CLI ships a `--refresh` flag, Invoke-ClaudeAuthRefresh and
#   Invoke-CodexAuthRefresh below are STUBS that throw NotImplementedException.
#   Tests Mock these helpers, which is the correct contract for this task.
#   Wire-up to the real refresh endpoint happens when the CLIs add support
#   (tracked in plan Task 12 follow-up). Search for "TODO(oauth-refresh-real)"
#   to find the integration points.

Set-StrictMode -Version Latest

# ── Module imports (idempotent) ──────────────────────────────────────────────
$Script:HubRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Structured logger (Task 2). Imported lazily so unit tests that Mock the logger
# can still load this script without the module on disk.
$loggerModule = Join-Path $Script:HubRoot 'aiox-shared\StructuredLogger.psm1'
if (Test-Path -LiteralPath $loggerModule) {
    Import-Module $loggerModule -Force -ErrorAction Stop
}

# ── Default log path ─────────────────────────────────────────────────────────
function Get-OAuthRefreshLogPath {
    [CmdletBinding()]
    param([string]$UserProfileOverride)
    $userProfile = if ($UserProfileOverride) { $UserProfileOverride } else { $env:USERPROFILE }
    return Join-Path $userProfile '.claude-orchestrator\usage\logs\oauth-refresh.jsonl'
}

# ── Refresh stubs (mocked in tests; see header note) ─────────────────────────
function Invoke-ClaudeAuthRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [string]$ConfigDir
    )
    # TODO(oauth-refresh-real): When `claude auth` exposes a non-interactive
    # refresh command, replace this body with:
    #   $env:CLAUDE_CONFIG_DIR = $ConfigDir
    #   & claude auth refresh --json
    # and parse the result.
    throw [System.NotImplementedException]::new(
        "Claude CLI does not yet expose a non-interactive auth refresh command. " +
        "This stub exists so tests can Mock it and so callers fail loudly if " +
        "wired up before CLI support lands."
    )
}

function Invoke-CodexAuthRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [string]$ConfigDir
    )
    # TODO(oauth-refresh-real): Codex stores refresh_token in auth.json. The
    # eventual implementation will POST to OpenAI's token endpoint with
    # grant_type=refresh_token and rewrite auth.json atomically.
    throw [System.NotImplementedException]::new(
        "Codex CLI auth refresh helper is not yet implemented. Mock in tests."
    )
}

# ── Auth-info adapter (delegates to manage-skills.ps1 Get-*AuthInfo) ─────────
# We do NOT dot-source manage-skills.ps1 here (heavy + side-effects). Tests Mock
# this adapter. Production callers must dot-source manage-skills.ps1 BEFORE
# calling Invoke-OAuthRefreshIfNeeded so Get-ClaudeAuthInfo / Get-CodexAuthInfo
# are in scope. The wrapper below picks the right one.
function Get-CliAuthInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex')][string]$CliType,
        [Parameter(Mandatory)][string]$ConfigDir
    )
    switch ($CliType) {
        'claude' {
            $cmd = Get-Command -Name 'Get-ClaudeAuthInfo' -ErrorAction SilentlyContinue
            if (-not $cmd) {
                throw "Get-ClaudeAuthInfo not in scope. Dot-source manage-skills.ps1 first."
            }
            return & $cmd -ConfigDir $ConfigDir
        }
        'codex' {
            $cmd = Get-Command -Name 'Get-CodexAuthInfo' -ErrorAction SilentlyContinue
            if (-not $cmd) {
                throw "Get-CodexAuthInfo not in scope. Dot-source manage-skills.ps1 first."
            }
            # manage-skills uses parameter -ProfileDir for codex variant.
            return & $cmd -ProfileDir $ConfigDir
        }
    }
}

# ── Profile -> ConfigDir resolver ────────────────────────────────────────────
function Resolve-CliProfileConfigDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex')][string]$CliType,
        [Parameter(Mandatory)][string]$ProfileName,
        [string]$UserProfileOverride
    )
    $userProfile = if ($UserProfileOverride) { $UserProfileOverride } else { $env:USERPROFILE }
    switch ($CliType) {
        'claude' { return Join-Path $userProfile (Join-Path '.claude-profiles' $ProfileName) }
        'codex'  { return Join-Path $userProfile (Join-Path '.codex-profiles'  $ProfileName) }
    }
}

# ── Public entry point ───────────────────────────────────────────────────────
function Invoke-OAuthRefreshIfNeeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex')][string]$CliType,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProfileName,
        # Buffer (seconds) below which we proactively refresh.
        [int]$ThresholdSeconds = 300,
        # Test hook: redirect log output without touching $env:USERPROFILE.
        [string]$LogPath,
        # Test hook: max attempts. Default 3 per spec.
        [int]$MaxAttempts = 3,
        # Test hook: provide pre-resolved ConfigDir (skips Resolve-CliProfileConfigDir).
        [string]$ConfigDirOverride,
        # Test hook: alternate USERPROFILE for path resolution.
        [string]$UserProfileOverride
    )

    if (-not $LogPath) {
        $LogPath = Get-OAuthRefreshLogPath -UserProfileOverride $UserProfileOverride
    }

    $configDir = if ($ConfigDirOverride) {
        $ConfigDirOverride
    } else {
        Resolve-CliProfileConfigDir -CliType $CliType -ProfileName $ProfileName -UserProfileOverride $UserProfileOverride
    }

    # 1. Read auth info to learn expiresIn.
    $authInfo = Get-CliAuthInfo -CliType $CliType -ConfigDir $configDir

    if (-not $authInfo) {
        # No credentials at all - nothing to refresh. Caller must handle login.
        Write-StructuredLog -Path $LogPath -Event 'oauth-refresh-skip' -Level 'warn' -Properties @{
            cliType     = $CliType
            profileName = $ProfileName
            reason      = 'no-auth-info'
        }
        return $false
    }

    # accessTokenExpiresIn is reported by Get-ClaudeAuthInfo and Get-CodexAuthInfo.
    # Treat $null as "unknown" -> conservatively skip (we have no signal to refresh).
    $expiresIn = $null
    if ($authInfo.PSObject -and $authInfo.PSObject.Properties['accessTokenExpiresIn']) {
        $expiresIn = $authInfo.accessTokenExpiresIn
    } elseif ($authInfo -is [System.Collections.IDictionary] -and $authInfo.Contains('accessTokenExpiresIn')) {
        $expiresIn = $authInfo['accessTokenExpiresIn']
    }

    if ($null -eq $expiresIn) {
        Write-StructuredLog -Path $LogPath -Event 'oauth-refresh-skip' -Level 'warn' -Properties @{
            cliType     = $CliType
            profileName = $ProfileName
            reason      = 'no-expires-in'
        }
        return $false
    }

    # 2. Skip if still healthy.
    if ([int]$expiresIn -ge $ThresholdSeconds) {
        Write-StructuredLog -Path $LogPath -Event 'oauth-refresh-skip' -Level 'info' -Properties @{
            cliType          = $CliType
            profileName      = $ProfileName
            expiresInSeconds = [int]$expiresIn
            threshold        = $ThresholdSeconds
            reason           = 'healthy'
        }
        return $true
    }

    # 3. Triggered: retry with exponential backoff (1s, 2s, 4s).
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-StructuredLog -Path $LogPath -Event 'oauth-refresh-attempt' -Level 'info' -Properties @{
            cliType          = $CliType
            profileName      = $ProfileName
            attempt          = $attempt
            maxAttempts      = $MaxAttempts
            expiresInSeconds = [int]$expiresIn
        }

        try {
            $refreshResult = $null
            switch ($CliType) {
                'claude' { $refreshResult = Invoke-ClaudeAuthRefresh -ProfileName $ProfileName -ConfigDir $configDir }
                'codex'  { $refreshResult = Invoke-CodexAuthRefresh  -ProfileName $ProfileName -ConfigDir $configDir }
            }

            # Convention: refresh helper returns $null/empty/explicit success.
            # Re-read auth info to confirm the new expiresIn.
            $newInfo = Get-CliAuthInfo -CliType $CliType -ConfigDir $configDir
            $newExpiresIn = $null
            if ($newInfo) {
                if ($newInfo.PSObject -and $newInfo.PSObject.Properties['accessTokenExpiresIn']) {
                    $newExpiresIn = $newInfo.accessTokenExpiresIn
                } elseif ($newInfo -is [System.Collections.IDictionary] -and $newInfo.Contains('accessTokenExpiresIn')) {
                    $newExpiresIn = $newInfo['accessTokenExpiresIn']
                }
            }

            Write-StructuredLog -Path $LogPath -Event 'oauth-refresh-success' -Level 'info' -Properties @{
                cliType          = $CliType
                profileName      = $ProfileName
                attempt          = $attempt
                expiresInSeconds = [int]($newExpiresIn ?? -1)
            }
            return $true
        } catch {
            $lastError = $_
            if ($attempt -lt $MaxAttempts) {
                # Exponential backoff: 1s, 2s, 4s, ...
                $backoff = [Math]::Pow(2, $attempt - 1)
                Start-Sleep -Seconds $backoff
            }
        }
    }

    Write-StructuredLog -Path $LogPath -Event 'oauth-refresh-fail' -Level 'error' -Properties @{
        cliType     = $CliType
        profileName = $ProfileName
        attempts    = $MaxAttempts
        lastError   = if ($lastError) { [string]$lastError.Exception.Message } else { 'unknown' }
    }
    return $false
}

# Function-level export only when dot-sourced inside a module; this script is
# meant to be dot-sourced by callers, so all functions defined above are
# already in the caller's scope. No Export-ModuleMember needed.
