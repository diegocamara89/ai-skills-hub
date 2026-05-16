#requires -Version 7.0
<#
.SYNOPSIS
    Setup AI Skills Hub. Cria diretórios pai de skills + shim CLI.
    NUNCA toca em perfis, junctions de auth, env vars de perfil ou Task Scheduler.
#>
[CmdletBinding()]
param(
    [switch]$SkipShim
)
$ErrorActionPreference = 'Stop'

Write-Host "AI Skills Hub setup started." -ForegroundColor Cyan

# 1. Garantir diretórios pai de skills (NÃO cria junctions individuais — feito via reconcile)
$skillRoots = @(
    "$env:USERPROFILE\.claude\skills",
    "$env:USERPROFILE\.codex\skills",
    "$env:USERPROFILE\.agents\skills",
    "$env:USERPROFILE\.qwen\skills",
    "$env:USERPROFILE\.antigravity\skills",
    "$env:USERPROFILE\.gemini\antigravity\skills",
    "$env:USERPROFILE\.gemini\extensions"
)
foreach ($p in $skillRoots) {
    if (-not (Test-Path $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        Write-Host "Created parent dir: $p"
    } else {
        Write-Host "Exists:             $p"
    }
}

# 2. Shim ai-skills.cmd
if (-not $SkipShim) {
    $shimDir = "$env:USERPROFILE\.local\bin"
    if (-not (Test-Path $shimDir)) { New-Item -ItemType Directory -Path $shimDir -Force | Out-Null }
    $shimPath = "$shimDir\ai-skills.cmd"
    @"
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\ai-skills.ps1" %*
"@ | Out-File -FilePath $shimPath -Encoding ascii -NoNewline
    Write-Host "Shim: $shimPath"
}

# 3. Pester check
$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version.Major -lt 5) {
    Write-Host "Pester 5+ nao encontrado. Rode: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "AI Skills Hub setup complete." -ForegroundColor Green
Write-Host ""
Write-Host "Para ativar skills:"
Write-Host '  .\manage-skills.ps1 enable-global -Skills napkin,doc,orchestrate'
Write-Host '  .\manage-skills.ps1 reconcile'

$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($userPath -notmatch [regex]::Escape("$env:USERPROFILE\.local\bin")) {
    Write-Host ""
    Write-Host "ATENCAO: ~\.local\bin NAO esta no PATH do usuario." -ForegroundColor Yellow
    Write-Host "Para usar o shim 'ai-skills' globalmente, adicione com:" -ForegroundColor Yellow
    Write-Host '  $newPath = ([Environment]::GetEnvironmentVariable(''PATH'',''User'')) + '';'' + "$env:USERPROFILE\.local\bin"' -ForegroundColor Cyan
    Write-Host '  [Environment]::SetEnvironmentVariable(''PATH'', $newPath, ''User'')' -ForegroundColor Cyan
}
