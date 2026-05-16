# Setup na outra maquina (pos-Syncthing)

O Syncthing sincroniza automaticamente: codigo, credenciais, settings por perfil,
scripts do collector e configuracoes do orquestrador.

Porem **5 itens sao locais por maquina** e precisam ser configurados manualmente
na primeira vez. Este documento explica o que fazer e por que.

---

## Pre-requisitos

- Syncthing rodando e com as pastas `claude-profiles`, `codex-profiles`,
  `claude-orchestrator` e `ai-skills-hub` aceitas e sincronizadas
- Claude Code CLI instalado (`claude --version` deve retornar 2.1.x)
- Codex CLI instalado (`codex --version` deve responder)
- Python 3.11+ instalado e no PATH
- Git Bash instalado (vem com Git for Windows)

---

## Passo 1: Junctions `active` (Claude e Codex)

### O que e

A junction `active` e um atalho NTFS que aponta para o perfil em uso.
O Claude Code e o Codex CLI leem configs e credenciais desse caminho.
O Syncthing nao sincroniza junctions (sao locais ao filesystem) —
precisa criar uma para cada provider.

### Claude

```powershell
if (Test-Path "$env:USERPROFILE\.claude-profiles\active") {
    Write-Host "Junction Claude ja existe. Target:"
    (Get-Item "$env:USERPROFILE\.claude-profiles\active" -Force).Target
} else {
    New-Item -ItemType Junction `
        -Path "$env:USERPROFILE\.claude-profiles\active" `
        -Target "$env:USERPROFILE\.claude-profiles\claude-a"
    Write-Host "Junction Claude criada: active -> claude-a"
}
```

### Codex

A junction Codex aponta SEMPRE para `~/.codex` (nao para os perfis).
A troca de conta e feita sobrescrevendo `auth.json` a partir do perfil
selecionado — sessions ficam compartilhadas em `~/.codex`.

```powershell
$codexReal = "$env:USERPROFILE\.codex"
$codexLink = "$env:USERPROFILE\.codex-profiles\active"
if (-not (Test-Path $codexReal)) {
    New-Item -ItemType Directory -Path $codexReal | Out-Null
}
if (Test-Path $codexLink) {
    Write-Host "Junction Codex ja existe. Target:"
    (Get-Item $codexLink -Force).Target
} else {
    New-Item -ItemType Junction -Path $codexLink -Target $codexReal
    Write-Host "Junction Codex criada: active -> ~/.codex"
}
```

Para trocar o perfil ativo (Claude ou Codex), use o painel web
(`abrir-painel-claude-auth.bat`) ou `ai-skills switch-to <nome>`.

---

## Passo 2: Variaveis de ambiente

### O que e

Claude Code usa `CLAUDE_CONFIG_DIR` e Codex CLI usa `CODEX_HOME` para saber onde
estao configs e credenciais do perfil ativo. Sem elas, cada CLI usa o default
(`~/.claude` e `~/.codex`) e ignora os perfis.

### 2a. CLAUDE_CONFIG_DIR

```powershell
[System.Environment]::SetEnvironmentVariable(
    "CLAUDE_CONFIG_DIR",
    "$env:USERPROFILE\.claude-profiles\active",
    "User"
)
Write-Host "CLAUDE_CONFIG_DIR setado."
```

### 2b. CODEX_HOME

```powershell
[System.Environment]::SetEnvironmentVariable(
    "CODEX_HOME",
    "$env:USERPROFILE\.codex-profiles\active",
    "User"
)
Write-Host "CODEX_HOME setado."
```

**Importante:** Feche e reabra o terminal apos setar para que as variaveis tenham efeito.

Para verificar:

```powershell
[System.Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "User")
[System.Environment]::GetEnvironmentVariable("CODEX_HOME", "User")
```

---

## Passo 3: Remover statusLine do settings.json global

### O que e

O arquivo `~/.claude/settings.json` (global) pode ter um `statusLine` que
sobrescreve o collector de cada perfil. Se isso acontecer, o dashboard web
nao recebe dados de uso. Cada perfil ja tem seu proprio `statusLine` configurado
pelo Syncthing — o global precisa ser removido para nao conflitar.

### Como fazer

Abra o arquivo:

```powershell
notepad "$env:USERPROFILE\.claude\settings.json"
```

Procure e **remova** o bloco `statusLine` inteiro. Exemplo do que remover:

```json
  "statusLine": {
    "type": "command",
    "command": "bash /c/Users/.../statusline-command.sh",
    "padding": 1
  }
```

**Atencao:** remova tambem a virgula que fica antes do bloco removido, para
manter o JSON valido. Se nao tiver certeza, valide em https://jsonlint.com

Se o arquivo nao existir ou nao tiver `statusLine`, nao precisa fazer nada.

---

## Passo 4: Task Scheduler ClaudeAutoRotate

### O que e

Tarefa agendada que verifica a cada 10 minutos se o perfil Claude ativo esta
proximo do limite de uso. Se estiver, troca automaticamente para o proximo
perfil disponivel. Sem esta tarefa, a rotacao so acontece se voce abrir o
painel ou rodar `ai-skills rotate` manualmente.

### Como criar

```powershell
$hubRoot = "$env:USERPROFILE\Diego\AI-Skills-Hub"  # ajuste se o path for outro
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hubRoot\auto-rotate.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 10) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName "ClaudeAutoRotate" `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Rotacao automatica de perfis Claude" -Force
```

Opcionalmente, crie tambem `ClaudeAutoRotateCodex` apontando para
`auto-rotate-codex.ps1`:

```powershell
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hubRoot\auto-rotate-codex.ps1`""
Register-ScheduledTask -TaskName "ClaudeAutoRotateCodex" `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "Rotacao automatica de perfis Codex" -Force
```

Para verificar se ja existem:

```powershell
Get-ScheduledTask -TaskName "ClaudeAutoRotate*" -ErrorAction SilentlyContinue
```

---

## Script automatico

Para conveniencia, execute o script abaixo que faz os 3 passos de uma vez:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\projetos\AI Skills Hub\setup-nova-maquina.ps1"
```

---

## Verificacao

Apos os 4 passos:

1. Abra um **novo terminal** (PowerShell ou Git Bash)
2. Execute `claude` — deve iniciar sem pedir login
3. Execute `codex --help` — deve rodar sem erro (se `codex` ja autenticado em outra maquina)
4. Envie uma mensagem no Claude — a statusline deve aparecer com barras visuais
5. Abra o painel (`abrir-painel-claude-auth.bat`) e clique "Atualizar Status"
   — os dados de uso do perfil ativo devem aparecer
6. Troque o perfil no painel — abra novo terminal — `claude` deve funcionar
   sem pedir login
7. Confirme que `ai-skills status` (do Hub) retorna status de ambos providers
8. Confirme que `Get-ScheduledTask -TaskName ClaudeAutoRotate` retorna a tarefa

---

## Troubleshooting

### Claude pede login ao abrir

- Verifique se a junction existe: `Get-Item "$env:USERPROFILE\.claude-profiles\active" -Force`
- Verifique se CLAUDE_CONFIG_DIR esta setado: `$env:CLAUDE_CONFIG_DIR`
- Verifique se o perfil tem `.credentials.json`: `Test-Path "$env:CLAUDE_CONFIG_DIR\.credentials.json"`
- Verifique se o perfil tem `hasCompletedOnboarding` no `.claude.json`

### Dashboard nao atualiza

- Verifique se `~/.claude/settings.json` NAO tem `statusLine` (o do perfil deve ser usado)
- Verifique se o perfil tem `statusLine` no settings.json: `Get-Content "$env:CLAUDE_CONFIG_DIR\settings.json" | Select-String statusLine`
- Verifique se `combined-statusline.sh` existe: `Test-Path "$env:USERPROFILE\.claude-orchestrator\statusline-tools\combined-statusline.sh"`
- Verifique se Python esta no PATH: `python --version`

### Junction nao funciona

- Deve ser criada com `New-Item -ItemType Junction` (NTFS junction, nao symlink)
- PowerShell deve rodar como Administrador na primeira vez
- O `.stignore` na pasta `.claude-profiles` protege a junction do Syncthing
