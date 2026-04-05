# auto-rotate.ps1 — Rotacao automatica de perfil Claude quando 5h ou 7d rate limit >= 95%
# Executado periodicamente via Windows Task Scheduler (a cada 10 minutos)
# Nao requer elevacao (admin). Atualiza CLAUDE_CONFIG_DIR na User env var.

param(
    [int]$Threshold = 95,   # % de uso que dispara rotacao
    [switch]$DryRun,        # Apenas logar, nao aplicar mudancas
    [switch]$Force          # Ignora threshold — rota imediatamente para o proximo perfil disponivel
)

$OrchestratorRoot = Join-Path $env:USERPROFILE ".claude-orchestrator"
$StateFile      = Join-Path $OrchestratorRoot "state.json"
$ConfigFile     = Join-Path $OrchestratorRoot "config.json"
$UsageRoot      = Join-Path $OrchestratorRoot "usage\profiles"
$LogFile        = Join-Path $OrchestratorRoot "usage\logs\rotation.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "$ts [$Level] $Message"
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Read-JsonFile {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    # Remover BOM se presente
    if ($raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    return $raw | ConvertFrom-Json
}

function Save-JsonFile {
    param([string]$Path, [object]$Data)
    $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function ConvertFrom-UnixTimestamp {
    param([long]$Timestamp)
    return [System.DateTimeOffset]::FromUnixTimeSeconds($Timestamp).UtcDateTime
}

function Show-RotationToast {
    param([string]$Title, [string]$Message)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $template.SelectSingleNode('//text[@id=1]').InnerText = $Title
        $template.SelectSingleNode('//text[@id=2]').InnerText = $Message
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Claude Auto-Rotate').Show($toast)
    } catch {
        Write-Log "Toast nao disponivel: $_" "WARN"
    }
}

# ── Garantir que diretorio de logs existe ──────────────────────────────────────
$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

Write-Log "auto-rotate iniciado (threshold=$Threshold%$(if ($DryRun) {', dry-run'})$(if ($Force) {', FORCE'}))"

# ── Ler state.json ─────────────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $StateFile)) {
    Write-Log "state.json nao encontrado: $StateFile" "ERROR"
    exit 1
}
$state = Read-JsonFile -Path $StateFile
$now   = [System.DateTime]::UtcNow

# ── 1. Reset de cooldowns expirados ───────────────────────────────────────────
$resetted = @()
foreach ($prop in $state.profiles.PSObject.Properties) {
    $p = $prop.Value
    if ($p.state -eq "cooldown" -and $p.cooldownUntil) {
        $until = [System.DateTime]::Parse($p.cooldownUntil).ToUniversalTime()
        if ($until -le $now) {
            Write-Log "Cooldown expirado para $($p.profileId) — restaurando para available"
            if (-not $DryRun) {
                $p.state        = "available"
                $p.cooldownUntil = $null
            }
            $resetted += $p.profileId
        }
    }
}

# ── 2. Identificar perfil ativo via CLAUDE_CONFIG_DIR ─────────────────────────
$configDir = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
if (-not $configDir) {
    Write-Log "CLAUDE_CONFIG_DIR nao definido — usando claude-a como fallback" "WARN"
    $configDir = Join-Path $env:USERPROFILE ".claude-profiles\claude-a"
}

# Extrair nome do perfil do caminho (ex: ...claude-profiles\claude-a => claude-a)
$activeProfile = ($configDir -split '[/\\]' | Where-Object { $_ -match '^claude-[a-z]$' } | Select-Object -Last 1)
if (-not $activeProfile) {
    Write-Log "Nao foi possivel extrair nome do perfil de: $configDir" "ERROR"
    exit 1
}

Write-Log "Perfil ativo: $activeProfile (CLAUDE_CONFIG_DIR=$configDir)"

# ── 3. Ler latest.json do perfil ativo ────────────────────────────────────────
$latestPath = Join-Path $UsageRoot "$activeProfile\latest.json"
if (-not (Test-Path -LiteralPath $latestPath)) {
    Write-Log "latest.json nao encontrado para $activeProfile — nada a fazer" "WARN"
    if ($resetted.Count -gt 0 -and -not $DryRun) {
        $state.updatedAt = $now.ToString("o")
        Save-JsonFile -Path $StateFile -Data $state
    }
    exit 0
}

$latest    = Read-JsonFile -Path $latestPath
$fiveHour  = $latest.rateLimits.fiveHour
$sevenDay  = $latest.rateLimits.sevenDay
$fivePct   = [double]($fiveHour.usedPercentage)
$sevenPct  = [double]($sevenDay.usedPercentage)

# Verificar idade do snapshot
$snapshotAge = $null
$snapshotField = if ($latest.rateLimitsSeenAt) { $latest.rateLimitsSeenAt } elseif ($latest.lastSeenAt) { $latest.lastSeenAt } else { $latest.observedAt }
if ($snapshotField) {
    try {
        $snapshotDt  = [System.DateTime]::Parse($snapshotField).ToUniversalTime()
        $snapshotAge = [int]($now - $snapshotDt).TotalMinutes
        if ($snapshotAge -gt 30 -and -not $Force) {
            Write-Log "AVISO: dados de $activeProfile com $snapshotAge min de idade — valores podem estar desatualizados. Use -Force para rotar manualmente." "WARN"
        }
    } catch {}
}

$ageLabel = if ($null -ne $snapshotAge) { " (dados com ${snapshotAge}min)" } else { "" }
Write-Log "Uso atual de $activeProfile — 5h: $fivePct% | 7d: $sevenPct%$ageLabel"

# ── 4. Verificar se rotacao e necessaria ──────────────────────────────────────
$triggerLimit  = $null
$triggerPct    = 0

if ($Force) {
    $triggerLimit = "FORCE"
    $triggerPct   = $fivePct
    Write-Log "Rotacao forcada manualmente — ignorando threshold" "WARN"
} elseif ($fivePct -ge $Threshold) {
    $triggerLimit = "5h"
    $triggerPct   = $fivePct
} elseif ($sevenPct -ge $Threshold) {
    $triggerLimit = "7d"
    $triggerPct   = $sevenPct
}

if (-not $triggerLimit) {
    Write-Log "Uso 5h ($fivePct%) e 7d ($sevenPct%) abaixo do threshold ($Threshold%) — sem rotacao necessaria"
    if ($resetted.Count -gt 0 -and -not $DryRun) {
        $state.updatedAt = $now.ToString("o")
        Save-JsonFile -Path $StateFile -Data $state
    }
    exit 0
}

if (-not $Force) {
    Write-Log "THRESHOLD ATINGIDO: $triggerLimit $triggerPct% >= $Threshold% — iniciando rotacao" "WARN"
}

# ── 5. Encontrar proximo perfil disponivel ────────────────────────────────────
$config   = Read-JsonFile -Path $ConfigFile
$profiles = @($config.profiles)  # array ordenado do config.json

$nextProfile    = $null
$nextConfigDir  = $null

foreach ($prof in $profiles) {
    $name = $prof.name
    if ($name -eq $activeProfile) { continue }

    $pState = $state.profiles.$name
    if (-not $pState) {
        Write-Log "Perfil $name esta no config.json mas nao em state.json — ignorando" "WARN"
        continue
    }

    # Checar loggedIn
    if (-not $pState.loggedIn) {
        Write-Log "Perfil $name nao esta logado — pulando"
        continue
    }

    # Checar cooldown
    if ($pState.cooldownUntil) {
        $until = [System.DateTime]::Parse($pState.cooldownUntil).ToUniversalTime()
        if ($until -gt $now) {
            $remaining = [int]($until - $now).TotalMinutes
            Write-Log "Perfil $name em cooldown por mais $remaining min — pulando"
            continue
        }
    }

    # Checar state
    if ($pState.state -notin @("available", "cooldown")) {
        # auth_required ou outro estado invalido
        Write-Log "Perfil $name em estado '$($pState.state)' — pulando"
        continue
    }

    # Candidato valido
    $nextProfile   = $name
    $nextConfigDir = $prof.config_dir
    break
}

if (-not $nextProfile) {
    $msg = "TODOS OS PERFIS EM COOLDOWN ou indisponiveis — nao e possivel rotar"
    Write-Log $msg "ERROR"
    if (-not $DryRun) {
        Show-RotationToast "Claude: limite atingido" "Todos os perfis em cooldown. Limite $triggerLimit : $triggerPct%"
        if ($resetted.Count -gt 0) {
            $state.updatedAt = $now.ToString("o")
            Save-JsonFile -Path $StateFile -Data $state
        }
    }
    exit 2
}

Write-Log "Proximo perfil selecionado: $nextProfile ($nextConfigDir)"

# ── 6. Aplicar rotacao ────────────────────────────────────────────────────────
if ($DryRun) {
    Write-Log "[DRY-RUN] Trocaria CLAUDE_CONFIG_DIR para $nextConfigDir"
    Write-Log "[DRY-RUN] Marcaria $activeProfile com cooldown ate $(ConvertFrom-UnixTimestamp -Timestamp $fiveHour.resetsAt)"
    exit 0
}

# 6a. Calcular cooldownUntil: usa resetsAt do limite que disparou a rotacao
$cooldownUntil = $null
$resetsAtSrc   = if ($triggerLimit -eq "7d") { $sevenDay.resetsAt } else { $fiveHour.resetsAt }

if ($resetsAtSrc) {
    $resetDt       = ConvertFrom-UnixTimestamp -Timestamp ([long]$resetsAtSrc)
    $cooldownUntil = $resetDt.ToString("o")
    Write-Log "Cooldown de $activeProfile ate $cooldownUntil (resetsAt=$resetsAtSrc, limite=$triggerLimit)"
} else {
    # Fallback: 5 horas a partir de agora
    $cooldownUntil = $now.AddHours(5).ToString("o")
    Write-Log "resetsAt ausente — usando fallback: cooldown por 5h" "WARN"
}

# 6b. Atualizar state.json: marcar perfil ativo como cooldown
$activeState               = $state.profiles.$activeProfile
$activeState.state         = "cooldown"
$activeState.cooldownUntil = $cooldownUntil

# 6c. Atualizar junction 'active' para o novo perfil (hot-swap sem alterar CLAUDE_CONFIG_DIR)
$profilesRoot = Split-Path $configDir -Parent
$activeLink   = Join-Path $profilesRoot "active"

# Garantir que CLAUDE_CONFIG_DIR aponta para a junction (valor fixo)
$envVal = [System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
if ($envVal -ne $activeLink) {
    [System.Environment]::SetEnvironmentVariable("CLAUDE_CONFIG_DIR", $activeLink, "User")
    Write-Log "CLAUDE_CONFIG_DIR fixado em $activeLink"
}

# Recriar junction apontando para o novo perfil
if (Test-Path -LiteralPath $activeLink) {
    $jItem = Get-Item -LiteralPath $activeLink -Force
    if (($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        [System.IO.Directory]::Delete($activeLink, $false)
    }
}
New-Item -ItemType Junction -Path $activeLink -Target $nextConfigDir | Out-Null
Write-Log "Junction atualizada: active -> $nextProfile ($nextConfigDir)"

# Atualizar marker sem BOM
$markerPath = Join-Path $env:USERPROFILE ".claude-active-dir"
[System.IO.File]::WriteAllText($markerPath, $activeLink, (New-Object System.Text.UTF8Encoding $false))

# 6d. Atualizar active_profile no state.json
$state.active_profile = $nextProfile
$state.updatedAt      = $now.ToString("o")
Save-JsonFile -Path $StateFile -Data $state

Write-Log "ROTACAO CONCLUIDA: $activeProfile -> $nextProfile" "INFO"
Write-Log "Cooldown de $activeProfile ate $cooldownUntil" "INFO"
Write-Log "Novos terminais usarao perfil: $nextProfile"

Show-RotationToast "Claude: perfil trocado" "$activeProfile -> $nextProfile  ($triggerLimit : $triggerPct%)"
