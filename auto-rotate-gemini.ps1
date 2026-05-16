# auto-rotate-gemini.ps1 — Rotacao automatica/manual de perfil Gemini CLI
# Plano: docs/superpowers/plans/2026-05-10-evolution-d.md  Task 7
#
# Diferente do Claude/Codex (que usam scripts dedicados com historia propria),
# Gemini delega 100% da decisao de swap para aiox-shared/CliRuntime.psm1.
#
# Uso:
#   .\auto-rotate-gemini.ps1 -List
#   .\auto-rotate-gemini.ps1 -Switch g2
#   .\auto-rotate-gemini.ps1 -Switch g2 -DryRun
#
# IMPORTANTE: o usuario pode nao ter perfis Gemini criados ainda. Os modos
# -List/-Status apenas reportam o estado atual; -Switch falha cedo com mensagem
# clara se a pasta de perfil nao existir (fail loud > side-effects misteriosos).

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Status,
    [switch]$List,
    [string]$Switch
)

Set-StrictMode -Version Latest

$cliRuntimePath = Join-Path $PSScriptRoot 'aiox-shared\CliRuntime.psm1'
if (-not (Test-Path -LiteralPath $cliRuntimePath)) {
    Write-Host "[ERROR] CliRuntime.psm1 nao encontrado em $cliRuntimePath" -ForegroundColor Red
    exit 1
}
Import-Module $cliRuntimePath -Force

$ProfilesRoot = Join-Path $env:USERPROFILE '.gemini-profiles'

if ($Status -or (-not $List -and -not $Switch)) {
    $envVal = [System.Environment]::GetEnvironmentVariable('GEMINI_CONFIG_DIR', 'User')
    Write-Host ""
    Write-Host "GEMINI_CONFIG_DIR (User): $(if ($envVal) { $envVal } else { '<not set>' })" -ForegroundColor Cyan
    Write-Host "Profiles root:            $ProfilesRoot"
    if (Test-Path -LiteralPath $ProfilesRoot) {
        $count = (Get-ChildItem -LiteralPath $ProfilesRoot -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host "Profile dirs found:       $count"
    } else {
        Write-Host "Profile dirs found:       0 (root nao existe)"
    }
    if ($Status) { exit 0 }
}

if ($List) {
    Write-Host ""
    if (-not (Test-Path -LiteralPath $ProfilesRoot)) {
        Write-Host "Nenhum perfil Gemini encontrado ($ProfilesRoot nao existe)." -ForegroundColor Yellow
        exit 0
    }
    Get-ChildItem -LiteralPath $ProfilesRoot -Directory | ForEach-Object {
        $p = Get-CliProfile -CliType 'gemini' -ProfileName $_.Name
        "{0,-15} {1,-12} {2}" -f $_.Name, $p.SwapMethod, $p.ConfigDir | Write-Host
    }
    exit 0
}

if ($Switch) {
    try {
        $r = Invoke-CliRotation -CliType 'gemini' -FromProfile '<unknown>' -ToProfile $Switch -DryRun:$DryRun
        Write-Host ""
        Write-Host ("Action:    {0}" -f $r.Action) -ForegroundColor Green
        Write-Host ("DryRun:    {0}" -f $r.DryRun)
        Write-Host ("EnvVar:    {0}" -f $r.EnvVarName)
        Write-Host ("ConfigDir: {0}" -f $r.ConfigDir)
        if (-not $DryRun) {
            Write-Host "Reabra terminais Gemini para aplicar a nova GEMINI_CONFIG_DIR." -ForegroundColor Yellow
        }
    } catch {
        Write-Host ("[ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    exit 0
}
