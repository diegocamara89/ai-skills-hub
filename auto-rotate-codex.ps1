# auto-rotate-codex.ps1 — Rotacao automatica de perfil Codex CLI
# Executado periodicamente via Windows Task Scheduler (a cada 10 minutos)
# Nao requer elevacao (admin). Atualiza CODEX_HOME na User env var via junction.

param(
    [int]$Threshold = 95,   # % de uso que dispara rotacao (baseado em arquivo .cooldown)
    [switch]$DryRun,        # Apenas logar, nao aplicar mudancas
    [switch]$Force          # Ignora threshold — rota imediatamente para o proximo perfil disponivel
)

$ProfilesRoot = Join-Path $env:USERPROFILE ".codex-profiles"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "$ts [$Level] $Message"
    Write-Host $line
}

function ConvertFrom-UnixTimestamp {
    param([long]$Timestamp)
    return [System.DateTimeOffset]::FromUnixTimeSeconds($Timestamp).UtcDateTime
}

function Get-ActiveProfileName {
    $codexHome = [System.Environment]::GetEnvironmentVariable("CODEX_HOME", "User")
    $activeLink = Join-Path $ProfilesRoot "active"

    if (-not $codexHome) {
        Write-Log "CODEX_HOME nao definido — sem perfil ativo conhecido" "WARN"
        return $null
    }

    if ($codexHome -ne $activeLink) {
        Write-Log "CODEX_HOME ($codexHome) nao aponta para a junction esperada ($activeLink)" "WARN"
    }

    if (-not (Test-Path -LiteralPath $activeLink)) {
        Write-Log "Junction $activeLink nao existe" "ERROR"
        return $null
    }

    $jItem = Get-Item -LiteralPath $activeLink -Force -ErrorAction SilentlyContinue
    if (-not $jItem -or ($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        Write-Log "$activeLink nao e uma junction" "ERROR"
        return $null
    }

    $rawTarget = $jItem.Target
    if ($rawTarget -is [System.Array]) { $rawTarget = $rawTarget[0] }
    $rawTarget = [string]$rawTarget
    if ($rawTarget.StartsWith('\??\'))  { $rawTarget = $rawTarget.Substring(4) }
    elseif ($rawTarget.StartsWith('\\?\')) { $rawTarget = $rawTarget.Substring(4) }

    return Split-Path $rawTarget -Leaf
}

function Get-AllCodexProfiles {
    if (-not (Test-Path -LiteralPath $ProfilesRoot)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $ProfilesRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "active" } |
        Select-Object -ExpandProperty Name
    )
}

function Get-ProfileUsagePct {
    param([string]$ProfileName)

    # Fonte primária: evento token_count nos arquivos de sessão JSONL
    $sessionsRoot = Join-Path $ProfilesRoot "$ProfileName\sessions"
    if (Test-Path -LiteralPath $sessionsRoot) {
        $latestFile = Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter "rollout-*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($latestFile) {
            try {
                $lines = [System.IO.File]::ReadAllLines($latestFile.FullName)
                for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                    if ($lines[$i] -notmatch '"rate_limits"') { continue }
                    $obj = $lines[$i] | ConvertFrom-Json
                    $rl = $obj.payload.rate_limits
                    if ($rl -and $rl.primary) {
                        return [ordered]@{
                            source   = "session-jsonl"
                            fivePct  = [double]$rl.primary.used_percent
                            sevenPct = if ($rl.secondary) { [double]$rl.secondary.used_percent } else { 0.0 }
                            resetsAt = [long]$rl.primary.resets_at
                        }
                    }
                }
            } catch {
                Write-Log "Falha ao ler session JSONL de ${ProfileName}: $_" "WARN"
            }
        }
    }

    # Fallback: arquivo .cooldown com timestamp Unix
    $cooldownPath = Join-Path $ProfilesRoot "$ProfileName\.cooldown"
    if (Test-Path -LiteralPath $cooldownPath) {
        try {
            $raw = (Get-Content -LiteralPath $cooldownPath -Raw -Encoding UTF8).Trim()
            $until = [long]$raw
            $now   = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ($until -gt $now) {
                # Perfil em cooldown — reportar 100%
                return [ordered]@{
                    source      = ".cooldown"
                    fivePct     = 100.0
                    sevenPct    = 0.0
                    resetsAt    = $until
                    cooldownUntil = (ConvertFrom-UnixTimestamp -Timestamp $until)
                }
            }
        } catch {
            Write-Log "Falha ao ler .cooldown de ${ProfileName}: $_" "WARN"
        }
    }

    return $null
}

function Set-ProfileCooldown {
    param([string]$ProfileName, [long]$ResetsAt)

    $cooldownPath = Join-Path $ProfilesRoot "$ProfileName\.cooldown"
    [System.IO.File]::WriteAllText($cooldownPath, "$ResetsAt", (New-Object System.Text.UTF8Encoding $false))
    Write-Log "Cooldown de $ProfileName gravado ate $(ConvertFrom-UnixTimestamp -Timestamp $ResetsAt) (arquivo .cooldown)"
}

function Set-CodexJunction {
    # Nova arquitetura: junction 'active' é FIXA -> ~/.codex
    # Trocar perfil = apenas substituir auth.json em ~/.codex
    param([string]$ProfileName)

    $realCodexDir = Join-Path $env:USERPROFILE ".codex"
    $profileAuth  = Join-Path $ProfilesRoot "$ProfileName\auth.json"

    if (-not (Test-Path -LiteralPath (Join-Path $ProfilesRoot $ProfileName))) {
        throw "Perfil Codex nao existe: $ProfileName"
    }

    # Copiar auth.json do perfil para ~/.codex (troca de conta)
    if (Test-Path -LiteralPath $profileAuth) {
        $bytes = [System.IO.File]::ReadAllBytes($profileAuth)
        [System.IO.File]::WriteAllBytes((Join-Path $realCodexDir "auth.json"), $bytes)
    }

    # Gravar marker de perfil ativo
    $markerPath = Join-Path $env:USERPROFILE ".codex-active-profile"
    [System.IO.File]::WriteAllText($markerPath, $ProfileName, (New-Object System.Text.UTF8Encoding $false))

    Write-Log "Codex: conta trocada para $ProfileName (sessions compartilhadas em ~/.codex)"
}

# ── Main ──────────────────────────────────────────────────────────────────────

Write-Log "auto-rotate-codex iniciado (threshold=$Threshold%$(if ($DryRun) {', dry-run'})$(if ($Force) {', FORCE'}))"

if (-not (Test-Path -LiteralPath $ProfilesRoot)) {
    Write-Log "Diretorio .codex-profiles nao existe: $ProfilesRoot" "ERROR"
    exit 1
}

$now           = [System.DateTime]::UtcNow
$activeProfile = Get-ActiveProfileName

if (-not $activeProfile) {
    Write-Log "Perfil Codex ativo nao identificado — encerrando" "ERROR"
    exit 1
}

Write-Log "Perfil Codex ativo: $activeProfile"

# Obter uso do perfil ativo
$usageData = Get-ProfileUsagePct -ProfileName $activeProfile

if (-not $usageData) {
    Write-Log "Nenhum dado de uso encontrado para $activeProfile — nada a fazer" "WARN"
    exit 0
}

$fivePct  = $usageData.fivePct
$sevenPct = $usageData.sevenPct
Write-Log "Uso de ${activeProfile} — fonte=$($usageData.source) | 5h: $fivePct% | 7d: $sevenPct%"

# Verificar se rotacao e necessaria
$triggerLimit = $null
$triggerPct   = 0

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
    exit 0
}

if (-not $Force) {
    Write-Log "THRESHOLD ATINGIDO: $triggerLimit $triggerPct% >= $Threshold% — iniciando rotacao" "WARN"
}

# Encontrar proximo perfil disponivel
$allProfiles = @(Get-AllCodexProfiles)
$nextProfile = $null

foreach ($prof in $allProfiles) {
    if ($prof -eq $activeProfile) { continue }

    # Verificar cooldown via .cooldown
    $cooldownPath = Join-Path $ProfilesRoot "$prof\.cooldown"
    if (Test-Path -LiteralPath $cooldownPath) {
        try {
            $raw   = (Get-Content -LiteralPath $cooldownPath -Raw -Encoding UTF8).Trim()
            $until = [long]$raw
            $nowTs = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if ($until -gt $nowTs) {
                $remaining = [int](($until - $nowTs) / 60)
                Write-Log "Perfil $prof em cooldown por mais $remaining min — pulando"
                continue
            }
        } catch {
            # arquivo corrompido — ignorar e considerar disponivel
        }
    }

    # Verificar latest.json se existir para cooldown via resetsAt
    $latestPath = Join-Path $ProfilesRoot "$prof\latest.json"
    if (Test-Path -LiteralPath $latestPath) {
        try {
            $raw    = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8
            $latest = $raw | ConvertFrom-Json
            $pct    = [double]($latest.rateLimits.fiveHour.usedPercentage)
            if ($pct -ge $Threshold) {
                Write-Log "Perfil $prof com ${pct}% de uso — pulando"
                continue
            }
        } catch {}
    }

    $nextProfile = $prof
    break
}

if (-not $nextProfile) {
    Write-Log "TODOS OS PERFIS CODEX indisponiveis — nao e possivel rotar" "ERROR"
    exit 2
}

Write-Log "Proximo perfil Codex selecionado: $nextProfile"

if ($DryRun) {
    Write-Log "[DRY-RUN] Trocaria junction Codex para $nextProfile"
    exit 0
}

# Calcular cooldown do perfil atual
$resetsAt = $null
if ($usageData.resetsAt) {
    $resetsAt = [long]$usageData.resetsAt
}
if (-not $resetsAt -or $resetsAt -le 0) {
    # Fallback: 5 horas a partir de agora
    $resetsAt = [System.DateTimeOffset]::UtcNow.AddHours(5).ToUnixTimeSeconds()
    Write-Log "resetsAt ausente — usando fallback: cooldown por 5h" "WARN"
}

Set-ProfileCooldown -ProfileName $activeProfile -ResetsAt $resetsAt
Set-CodexJunction -ProfileName $nextProfile

Write-Log "ROTACAO CODEX CONCLUIDA: $activeProfile -> $nextProfile ($triggerLimit : $triggerPct%)" "INFO"
Write-Log "Novos processos Codex usarao perfil: $nextProfile"
