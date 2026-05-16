#requires -Version 7.0
<#
Verifica pré-requisitos antes de iniciar a migração split AI-Skills-Hub.
Sai com código 0 se tudo OK, 1 se algo falta.
#>
[CmdletBinding()]
param(
    [string]$OutPath = "$PSScriptRoot\preflight-results.json"
)
$ErrorActionPreference = "Stop"

$results = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    checks    = [ordered]@{}
}

function Add-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $results.checks[$Name] = [ordered]@{
        pass   = $Pass
        detail = $Detail
    }
    $marker = if ($Pass) { 'PASS' } else { 'FAIL' }
    Write-Host "[$marker] $Name - $Detail"
}

# PowerShell 7
Add-Check 'powershell_7' ($PSVersionTable.PSVersion.Major -ge 7) "version=$($PSVersionTable.PSVersion)"

# Pester 5
$pesterModule = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
$pesterOk = $pesterModule -and $pesterModule.Version.Major -ge 5
Add-Check 'pester_5' $pesterOk "version=$($pesterModule.Version)"

# .NET 8+ SDK (Spectre.Console compatible)
try {
    $dotnetVersion = & dotnet --version 2>$null
    $dotnetMajor = ($dotnetVersion -split '\.')[0]
    $dotnetOk = [int]$dotnetMajor -ge 8
} catch { $dotnetOk = $false; $dotnetVersion = 'not found' }
Add-Check 'dotnet_8plus' $dotnetOk "version=$dotnetVersion"

# gh CLI
try {
    $ghVersion = (& gh --version 2>$null | Select-Object -First 1)
    $ghOk = [bool]$ghVersion
} catch { $ghOk = $false; $ghVersion = 'not found' }
Add-Check 'gh_cli' $ghOk "version=$ghVersion"

# git
try {
    $gitVersion = (& git --version 2>$null)
    $gitOk = [bool]$gitVersion
} catch { $gitOk = $false; $gitVersion = 'not found' }
Add-Check 'git' $gitOk "version=$gitVersion"

# robocopy
$robocopyOk = $null -ne (Get-Command robocopy.exe -ErrorAction SilentlyContinue)
Add-Check 'robocopy' $robocopyOk 'built-in Windows tool'

# Profile directories exist
$claudeProfilesExist = Test-Path "$env:USERPROFILE\.claude-profiles"
$codexProfilesExist = Test-Path "$env:USERPROFILE\.codex-profiles"
Add-Check 'claude_profiles_dir' $claudeProfilesExist "path=$env:USERPROFILE\.claude-profiles"
Add-Check 'codex_profiles_dir' $codexProfilesExist "path=$env:USERPROFILE\.codex-profiles"

# Active profile paths (junction OR regular dir — both work; just need to exist with content)
function Get-ActiveProfileInfo {
    param([string]$Path, [string[]]$ExpectedFiles)
    if (-not (Test-Path $Path)) { return @{ ok = $false; detail = 'missing' } }
    $item = Get-Item $Path -Force
    $linkInfo = if ($item.LinkType -eq 'Junction') { "junction -> $($item.Target -join ',')" } else { 'regular dir' }
    $foundFiles = $ExpectedFiles | Where-Object { Test-Path (Join-Path $Path $_) }
    $hasContent = $foundFiles.Count -gt 0
    return @{
        ok     = $hasContent
        detail = "$linkInfo, found=$($foundFiles -join '/')"
    }
}
$claudeInfo = Get-ActiveProfileInfo "$env:USERPROFILE\.claude-profiles\active" @('.credentials.json','settings.json','.claude.json')
$codexInfo  = Get-ActiveProfileInfo "$env:USERPROFILE\.codex-profiles\active"  @('auth.json','config.toml','sessions','sqlite')
Add-Check 'claude_active'  $claudeInfo.ok $claudeInfo.detail
Add-Check 'codex_active'   $codexInfo.ok  $codexInfo.detail

# Env vars
Add-Check 'env_claude_config_dir' ([bool]$env:CLAUDE_CONFIG_DIR) "value=$env:CLAUDE_CONFIG_DIR"
Add-Check 'env_codex_home'        ([bool]$env:CODEX_HOME)        "value=$env:CODEX_HOME"

# Task Scheduler tasks
function Test-TaskExists {
    param([string]$Name)
    try { $t = Get-ScheduledTask -TaskName $Name -ErrorAction Stop; return $t.State.ToString() } catch { return $null }
}
$claudeRotate = Test-TaskExists 'ClaudeAutoRotate'
$codexRotate  = Test-TaskExists 'CodexAutoRotate'
Add-Check 'task_claude_rotate' ([bool]$claudeRotate) "state=$claudeRotate"
Add-Check 'task_codex_rotate'  ([bool]$codexRotate)  "state=$codexRotate"

# GitHub repo reachable
try {
    $repoCheck = & gh repo view diegocamara89/ai-skills-hub --json name -q '.name' 2>$null
    $repoOk = $repoCheck -eq 'ai-skills-hub'
} catch { $repoOk = $false }
Add-Check 'github_repo_reachable' $repoOk 'repo=diegocamara89/ai-skills-hub'

# Disk space
$drive = Get-PSDrive C
$freeMB = [math]::Round($drive.Free / 1MB, 0)
Add-Check 'disk_space_5gb' ($freeMB -gt 5120) "free=${freeMB}MB"

# PATH includes ~\.local\bin
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$localBin = "$env:USERPROFILE\.local\bin"
$pathOk = $userPath -split ';' | Where-Object { $_.Trim() -eq $localBin }
Add-Check 'path_local_bin' ([bool]$pathOk) "user_path_contains=$localBin"

# Scheduled Task registration permission
try {
    $testTask = "PreflightTest_$(Get-Random)"
    $action  = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c echo test'
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddYears(10))
    Register-ScheduledTask -TaskName $testTask -Action $action -Trigger $trigger -ErrorAction Stop | Out-Null
    Unregister-ScheduledTask -TaskName $testTask -Confirm:$false -ErrorAction Stop
    $schedOk = $true; $schedDetail = 'can register'
} catch {
    $schedOk = $false; $schedDetail = $_.Exception.Message
}
Add-Check 'scheduler_can_register' $schedOk $schedDetail

# CLI processes — informational only, won't fail preflight (matters only in phase 4 cutover)
$claudeProc = @(Get-Process -Name claude -ErrorAction SilentlyContinue)
$codexProc  = @(Get-Process -Name codex  -ErrorAction SilentlyContinue)
$results.checks['cli_processes_info'] = [ordered]@{
    pass   = $true
    detail = "claude=$($claudeProc.Count) codex=$($codexProc.Count) (must be 0 only during phase 4)"
}
Write-Host "[INFO] cli_processes_info - claude=$($claudeProc.Count) codex=$($codexProc.Count) (matters in phase 4)"

$allPass = -not ($results.checks.Values | Where-Object { -not $_.pass })
$results | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutPath -Encoding utf8
Write-Host ""
if ($allPass) {
    Write-Host "ALL CHECKS PASS. Results: $OutPath" -ForegroundColor Green
    exit 0
} else {
    Write-Host "SOME CHECKS FAILED. Review: $OutPath" -ForegroundColor Yellow
    exit 1
}
