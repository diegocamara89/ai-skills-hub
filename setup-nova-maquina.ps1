<#
.SYNOPSIS
    Configura uma nova maquina para usar o sistema multi-perfil Claude Code.
    Execute apos o Syncthing sincronizar as pastas claude-profiles e claude-orchestrator.

.DESCRIPTION
    Faz 3 coisas que nao podem ser sincronizadas via Syncthing:
    1. Cria a junction NTFS 'active' em .claude-profiles
    2. Seta CLAUDE_CONFIG_DIR como variavel de ambiente do usuario
    3. Remove statusLine conflitante do settings.json global (~/.claude/)

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "setup-nova-maquina.ps1"
    powershell -NoProfile -ExecutionPolicy Bypass -File "setup-nova-maquina.ps1" -DefaultProfile claude-b
#>
param(
    [string]$DefaultProfile = "claude-a",
    [string]$DefaultCodexProfile = "codex-a",
    [switch]$SkipCodex,
    [switch]$SkipScheduler,
    [switch]$SkipAiSkillsShim
)

$ErrorActionPreference = "Stop"
$profilesRoot = Join-Path $env:USERPROFILE ".claude-profiles"
$activeLink = Join-Path $profilesRoot "active"
$globalSettingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
$codexProfilesRoot = Join-Path $env:USERPROFILE ".codex-profiles"
$codexActiveLink   = Join-Path $codexProfilesRoot "active"
$codexRealDir      = Join-Path $env:USERPROFILE ".codex"
$hubRoot = $PSScriptRoot
if (-not $hubRoot) { $hubRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

Write-Host ""
Write-Host "=== Setup Multi-Perfil Claude Code ===" -ForegroundColor Cyan
Write-Host ""

# ── Validacoes ──────────────────────────────────────────────────────────────

$targetProfile = Join-Path $profilesRoot $DefaultProfile
if (-not (Test-Path -LiteralPath $targetProfile)) {
    Write-Host "ERRO: Perfil '$DefaultProfile' nao encontrado em $profilesRoot" -ForegroundColor Red
    Write-Host "Perfis disponiveis:"
    Get-ChildItem $profilesRoot -Directory | Where-Object { $_.Name -ne "active" } | ForEach-Object {
        Write-Host "  - $($_.Name)"
    }
    Write-Host ""
    Write-Host "Execute novamente com: -DefaultProfile <nome>" -ForegroundColor Yellow
    exit 1
}

# ── Passo 1: Junction 'active' ─────────────────────────────────────────────

Write-Host "[1/6] Junction Claude 'active'" -ForegroundColor White
if (Test-Path -LiteralPath $activeLink) {
    $item = Get-Item -LiteralPath $activeLink -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $currentTarget = $item.Target
        Write-Host "  Ja existe: active -> $currentTarget" -ForegroundColor Green
        Write-Host "  (para trocar, use o painel web ou recrie manualmente)" -ForegroundColor DarkGray
    } else {
        Write-Host "  AVISO: '$activeLink' existe mas NAO e uma junction!" -ForegroundColor Yellow
        Write-Host "  Remova manualmente e execute novamente." -ForegroundColor Yellow
    }
} else {
    New-Item -ItemType Junction -Path $activeLink -Target $targetProfile | Out-Null
    Write-Host "  Criada: active -> $DefaultProfile" -ForegroundColor Green
}

# ── Passo 2: CLAUDE_CONFIG_DIR ──────────────────────────────────────────────

Write-Host "[2/6] Variavel CLAUDE_CONFIG_DIR" -ForegroundColor White
$currentEnv = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
if ($currentEnv -eq $activeLink) {
    Write-Host "  Ja configurada: $currentEnv" -ForegroundColor Green
} else {
    [System.Environment]::SetEnvironmentVariable("CLAUDE_CONFIG_DIR", $activeLink, "User")
    $env:CLAUDE_CONFIG_DIR = $activeLink
    if ($currentEnv) {
        Write-Host "  Atualizada: $currentEnv -> $activeLink" -ForegroundColor Green
    } else {
        Write-Host "  Configurada: $activeLink" -ForegroundColor Green
    }
}

# ── Passo 3: Remover statusLine do global ───────────────────────────────────

Write-Host "[3/6] StatusLine global (~/.claude/settings.json)" -ForegroundColor White
if (Test-Path -LiteralPath $globalSettingsPath) {
    try {
        $raw = Get-Content -LiteralPath $globalSettingsPath -Raw
        $settings = $raw | ConvertFrom-Json

        if ($settings.PSObject.Properties["statusLine"]) {
            $settings.PSObject.Properties.Remove("statusLine")
            $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $globalSettingsPath -Encoding UTF8
            Write-Host "  Removido statusLine conflitante do global" -ForegroundColor Green
        } else {
            Write-Host "  Nenhum statusLine no global (OK)" -ForegroundColor Green
        }
    } catch {
        Write-Host "  AVISO: Nao foi possivel processar $globalSettingsPath" -ForegroundColor Yellow
        Write-Host "  Remova o bloco 'statusLine' manualmente com um editor." -ForegroundColor Yellow
    }
} else {
    Write-Host "  Arquivo global nao existe (OK)" -ForegroundColor Green
}

# ── Passo 4: Codex (junction + CODEX_HOME) ─────────────────────────────────

Write-Host "[4/6] Codex (junction + CODEX_HOME)" -ForegroundColor White
if ($SkipCodex) {
    Write-Host "  Pulado (-SkipCodex)" -ForegroundColor DarkGray
} else {
    if (-not (Test-Path -LiteralPath $codexRealDir)) {
        New-Item -ItemType Directory -Path $codexRealDir -Force | Out-Null
        Write-Host "  Criado: ~/.codex" -ForegroundColor Green
    }
    if (-not (Test-Path -LiteralPath $codexProfilesRoot)) {
        New-Item -ItemType Directory -Path $codexProfilesRoot -Force | Out-Null
    }

    if (Test-Path -LiteralPath $codexActiveLink) {
        $cItem = Get-Item -LiteralPath $codexActiveLink -Force
        if (($cItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-Host "  Junction Codex ja existe: active -> $($cItem.Target)" -ForegroundColor Green
        } else {
            Write-Host "  AVISO: '$codexActiveLink' existe mas NAO e uma junction" -ForegroundColor Yellow
        }
    } else {
        New-Item -ItemType Junction -Path $codexActiveLink -Target $codexRealDir | Out-Null
        Write-Host "  Criada: active -> ~/.codex" -ForegroundColor Green
    }

    $currentCodexHome = [System.Environment]::GetEnvironmentVariable("CODEX_HOME", "User")
    if ($currentCodexHome -eq $codexActiveLink) {
        Write-Host "  CODEX_HOME ja configurada: $currentCodexHome" -ForegroundColor Green
    } else {
        [System.Environment]::SetEnvironmentVariable("CODEX_HOME", $codexActiveLink, "User")
        $env:CODEX_HOME = $codexActiveLink
        Write-Host "  CODEX_HOME configurada: $codexActiveLink" -ForegroundColor Green
    }

    # Criar perfil default se nao existir (copia auth.json do ~/.codex)
    $defaultCodexDir = Join-Path $codexProfilesRoot $DefaultCodexProfile
    if (-not (Test-Path -LiteralPath $defaultCodexDir)) {
        New-Item -ItemType Directory -Path $defaultCodexDir -Force | Out-Null
        $origAuth = Join-Path $codexRealDir "auth.json"
        $destAuth = Join-Path $defaultCodexDir "auth.json"
        if (Test-Path -LiteralPath $origAuth) {
            Copy-Item -LiteralPath $origAuth -Destination $destAuth -Force
            Write-Host "  Perfil default criado: $DefaultCodexProfile (com auth.json existente)" -ForegroundColor Green
        } else {
            [System.IO.File]::WriteAllText($destAuth, "{}")
            Write-Host "  Perfil default criado: $DefaultCodexProfile (sem auth — faca login depois)" -ForegroundColor Yellow
        }
    }

    $codexMarker = Join-Path $env:USERPROFILE ".codex-active-profile"
    if (-not (Test-Path -LiteralPath $codexMarker)) {
        [System.IO.File]::WriteAllText($codexMarker, $DefaultCodexProfile)
        Write-Host "  Marker ativo: $DefaultCodexProfile" -ForegroundColor Green
    }
}

# ── Passo 5: Task Scheduler ClaudeAutoRotate ───────────────────────────────

Write-Host "[5/6] Task Scheduler ClaudeAutoRotate" -ForegroundColor White
if ($SkipScheduler) {
    Write-Host "  Pulado (-SkipScheduler)" -ForegroundColor DarkGray
} else {
    $rotateScript = Join-Path $hubRoot "auto-rotate.ps1"
    if (-not (Test-Path -LiteralPath $rotateScript)) {
        Write-Host "  AVISO: $rotateScript nao encontrado — aguarde Syncthing" -ForegroundColor Yellow
    } else {
        $existing = Get-ScheduledTask -TaskName "ClaudeAutoRotate" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "  ClaudeAutoRotate ja registrada" -ForegroundColor Green
        } else {
            try {
                $argList = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$rotateScript`""
                $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argList
                $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                    -RepetitionInterval (New-TimeSpan -Minutes 10) `
                    -RepetitionDuration (New-TimeSpan -Days 3650)
                $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                Register-ScheduledTask -TaskName "ClaudeAutoRotate" `
                    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                    -Description "Rotacao automatica de perfis Claude" -Force | Out-Null
                Write-Host "  Registrada: ClaudeAutoRotate (a cada 10min)" -ForegroundColor Green
            } catch {
                Write-Host "  AVISO: falha ao registrar — $_" -ForegroundColor Yellow
            }
        }

        # Opcional: tambem registrar Codex se o script existir
        $rotateCodex = Join-Path $hubRoot "auto-rotate-codex.ps1"
        if ((Test-Path -LiteralPath $rotateCodex) -and -not (Get-ScheduledTask -TaskName "ClaudeAutoRotateCodex" -ErrorAction SilentlyContinue)) {
            try {
                $argList = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$rotateCodex`""
                $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argList
                Register-ScheduledTask -TaskName "ClaudeAutoRotateCodex" `
                    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                    -Description "Rotacao automatica de perfis Codex" -Force | Out-Null
                Write-Host "  Registrada: ClaudeAutoRotateCodex" -ForegroundColor Green
            } catch {}
        }
    }
}

# ── Passo 6: Shim ai-skills no PATH ─────────────────────────────────────────

Write-Host "[6/6] ai-skills CLI shim" -ForegroundColor White
if ($SkipAiSkillsShim) {
    Write-Host "  Pulado (-SkipAiSkillsShim)" -ForegroundColor DarkGray
} else {
    $aiSkillsSrc = Join-Path $hubRoot "ai-skills.ps1"
    if (-not (Test-Path -LiteralPath $aiSkillsSrc)) {
        Write-Host "  AVISO: $aiSkillsSrc nao encontrado" -ForegroundColor Yellow
    } else {
        $localBin = Join-Path $env:USERPROFILE ".local\bin"
        if (-not (Test-Path -LiteralPath $localBin)) {
            New-Item -ItemType Directory -Path $localBin -Force | Out-Null
        }
        $cmdShim = Join-Path $localBin "ai-skills.cmd"
        $cmdContent = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$aiSkillsSrc`" %*`r`n"
        [System.IO.File]::WriteAllText($cmdShim, $cmdContent)
        Write-Host "  Shim criado: $cmdShim" -ForegroundColor Green

        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
        if ($userPath -notlike "*$localBin*") {
            [System.Environment]::SetEnvironmentVariable("PATH", "$userPath;$localBin", "User")
            Write-Host "  $localBin adicionado ao PATH do usuario" -ForegroundColor Green
        }
    }
}

# ── Resumo ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== Setup concluido ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Proximo passo: feche este terminal e abra um novo." -ForegroundColor Yellow
Write-Host "Execute 'claude' — deve iniciar sem pedir login." -ForegroundColor Yellow
Write-Host ""

# Verificacao rapida
$credPath = Join-Path $activeLink ".credentials.json"
$claudeJsonPath = Join-Path $activeLink ".claude.json"
if (Test-Path -LiteralPath $credPath) {
    Write-Host "  Credenciais: encontradas" -ForegroundColor Green
} else {
    Write-Host "  Credenciais: NAO encontradas — pode precisar logar" -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $claudeJsonPath) {
    $cj = Get-Content -LiteralPath $claudeJsonPath -Raw | ConvertFrom-Json
    if ($cj.PSObject.Properties["hasCompletedOnboarding"] -and $cj.hasCompletedOnboarding) {
        Write-Host "  Onboarding: completo" -ForegroundColor Green
    } else {
        Write-Host "  Onboarding: incompleto — pode pedir login" -ForegroundColor Yellow
    }
} else {
    Write-Host "  .claude.json: NAO encontrado" -ForegroundColor Yellow
}

$combinedSh = Join-Path $env:USERPROFILE ".claude-orchestrator\statusline-tools\combined-statusline.sh"
if (Test-Path -LiteralPath $combinedSh) {
    Write-Host "  StatusLine collector: encontrado" -ForegroundColor Green
} else {
    Write-Host "  StatusLine collector: NAO encontrado — aguarde Syncthing" -ForegroundColor Yellow
}

Write-Host ""
