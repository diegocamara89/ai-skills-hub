<#
.SYNOPSIS
    CLI wrapper para o painel Claude Auth / Codex Auth (manage-skills.ps1).

.DESCRIPTION
    Fala com o servidor HTTP local (porta 8766 para claude-auth-ui,
    fallback 8765 para manage-skills geral). Se o servidor nao estiver
    rodando, sugere abrir o painel via abrir-painel-claude-auth.bat.

.EXAMPLE
    ai-skills list
    ai-skills list -Provider codex
    ai-skills switch-to claude-b
    ai-skills status
    ai-skills instances
    ai-skills rotate
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("list", "switch", "switch-to", "status", "instances", "rotate", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Target,

    [ValidateSet("claude", "codex")]
    [string]$Provider = "claude",

    [int[]]$Ports = @(8766, 8765)
)

$ErrorActionPreference = "Stop"

function Find-AiSkillsBase {
    param([int[]]$PortList)
    foreach ($port in $PortList) {
        try {
            $null = Invoke-RestMethod -Uri "http://localhost:$port/api/runtime/instances" -TimeoutSec 2 -ErrorAction Stop
            return "http://localhost:$port"
        } catch {
            continue
        }
    }
    throw "Nenhum servidor ai-skills encontrado nas portas: $($PortList -join ', '). Abra o painel com abrir-painel-claude-auth.bat."
}

function Invoke-Api {
    param([string]$Base, [string]$Path, [string]$Method = "GET", $Body = $null)
    $uri = "$Base$Path"
    $params = @{ Uri = $uri; Method = $Method; TimeoutSec = 15 }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 6)
        $params.ContentType = "application/json"
    }
    return Invoke-RestMethod @params
}

switch ($Command) {
    "help" {
        Write-Host ""
        Write-Host "ai-skills — CLI multi-perfil Claude + Codex" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Comandos:" -ForegroundColor White
        Write-Host "  list                     Lista perfis (use -Provider claude|codex)"
        Write-Host "  switch                   Alias para list (mostra candidatos)"
        Write-Host "  switch-to <nome>         Ativa o perfil <nome>"
        Write-Host "  status                   Status resumido de ambos providers"
        Write-Host "  instances                Processos Claude/Codex em execucao"
        Write-Host "  rotate                   Forca rotacao (Claude)"
        Write-Host ""
        Write-Host "Exemplos:" -ForegroundColor White
        Write-Host "  ai-skills list"
        Write-Host "  ai-skills list -Provider codex"
        Write-Host "  ai-skills switch-to claude-b"
        Write-Host "  ai-skills instances"
        Write-Host ""
        return
    }
}

$base = Find-AiSkillsBase -PortList $Ports

switch ($Command) {
    "list" {
        if ($Provider -eq "claude") {
            $data = Invoke-Api -Base $base -Path "/api/claude-auth/status"
            $data.profiles | ForEach-Object {
                $marker = if ($_.isActive) { "*" } else { " " }
                $state = if ($_.loggedIn) { $_.tierLabel } else { "DESLOGADO" }
                $tokenTxt = if ($_.accessTokenExpiresIn) {
                    $s = [int]$_.accessTokenExpiresIn
                    if ($s -le 0) { "EXPIRADO" }
                    elseif ($s -lt 3600) { "{0}m" -f [int]($s / 60) }
                    elseif ($s -lt 86400) { "{0}h" -f [int]($s / 3600) }
                    else { "{0}d" -f [int]($s / 86400) }
                } else { "--" }
                "{0} {1,-12} {2,-10} token={3,-8} email={4}" -f $marker, $_.name, $state, $tokenTxt, $_.email
            }
            if ($data.aggregatePool) {
                Write-Host ""
                Write-Host ("Pool agregado: {0:N1}% / {1}x capacidade" -f $data.aggregatePool.availabilityPercentage, $data.aggregatePool.totalCapacity) -ForegroundColor Cyan
            }
        } else {
            $data = Invoke-Api -Base $base -Path "/api/codex-auth/profiles"
            $data.profiles | ForEach-Object {
                $marker = if ($_.isActive) { "*" } else { " " }
                $state = if ($_.hasAuth) { [string]$_.planType } else { "sem auth" }
                "{0} {1,-12} plan={2,-8} email={3}" -f $marker, $_.name, $state, $_.email
            }
        }
    }
    "switch" {
        # Mesma saida de list — ajuda a escolher
        & $PSCommandPath -Command list -Provider $Provider
    }
    "switch-to" {
        if (-not $Target) { throw "Informe o nome do perfil: ai-skills switch-to <nome>" }
        if ($Provider -eq "claude") {
            $null = Invoke-Api -Base $base -Path "/api/claude-auth/set-active" -Method POST -Body @{ profile = $Target }
            Write-Host "Claude: perfil ativo -> $Target" -ForegroundColor Green
        } else {
            $null = Invoke-Api -Base $base -Path "/api/codex-auth/set-active" -Method POST -Body @{ name = $Target }
            Write-Host "Codex: perfil ativo -> $Target" -ForegroundColor Green
        }
    }
    "status" {
        $claude = Invoke-Api -Base $base -Path "/api/claude-auth/status"
        Write-Host ""
        Write-Host "CLAUDE" -ForegroundColor Cyan
        Write-Host ("  Ativo: {0}" -f $claude.activeProfile)
        Write-Host ("  Perfis: {0} (logados: {1})" -f @($claude.profiles).Count, @($claude.profiles | Where-Object { $_.loggedIn }).Count)
        if ($claude.aggregatePool) {
            Write-Host ("  Pool: {0:N1}% disponivel / {1}x capacidade" -f $claude.aggregatePool.availabilityPercentage, $claude.aggregatePool.totalCapacity)
        }

        try {
            $codex = Invoke-Api -Base $base -Path "/api/codex-auth/profiles"
            Write-Host ""
            Write-Host "CODEX" -ForegroundColor Cyan
            $active = @($codex.profiles | Where-Object { $_.isActive }) | Select-Object -First 1
            Write-Host ("  Ativo: {0}" -f $(if ($active) { $active.name } else { "--" }))
            Write-Host ("  Perfis: {0} (com auth: {1})" -f @($codex.profiles).Count, @($codex.profiles | Where-Object { $_.hasAuth }).Count)
        } catch {
            Write-Host ""
            Write-Host "CODEX: indisponivel ($_)" -ForegroundColor DarkGray
        }

        $inst = Invoke-Api -Base $base -Path "/api/runtime/instances"
        Write-Host ""
        Write-Host "EXECUCAO" -ForegroundColor Cyan
        Write-Host ("  Claude: {0} instancia(s)" -f $inst.claude.count)
        Write-Host ("  Codex:  {0} instancia(s)" -f $inst.codex.count)
        Write-Host ""
    }
    "instances" {
        $inst = Invoke-Api -Base $base -Path "/api/runtime/instances"
        Write-Host ""
        Write-Host ("Claude: {0} instancia(s)" -f $inst.claude.count) -ForegroundColor Cyan
        $inst.claude.processes | ForEach-Object { Write-Host ("  PID {0,6}  profile={1,-12} name={2}" -f $_.pid, $_.profile, $_.name) }
        Write-Host ""
        Write-Host ("Codex: {0} instancia(s)" -f $inst.codex.count) -ForegroundColor Cyan
        $inst.codex.processes | ForEach-Object { Write-Host ("  PID {0,6}  profile={1,-12} name={2}" -f $_.pid, $_.profile, $_.name) }
        Write-Host ""
    }
    "rotate" {
        $null = Invoke-Api -Base $base -Path "/api/force-rotate" -Method POST -Body @{}
        Write-Host "Rotacao Claude forcada." -ForegroundColor Green
    }
}
