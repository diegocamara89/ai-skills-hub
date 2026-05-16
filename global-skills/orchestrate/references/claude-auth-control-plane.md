# Claude Auth Control Plane

## Objetivo

Este projeto consolidou um plano operacional para usar `Claude Code` como orquestrador principal no Windows, com:

- multiplos perfis Claude persistentes no mesmo usuario
- failover reativo por cota
- painel web para login e observabilidade
- coleta local de uso sem gastar tokens extras
- selecao explicita de modelo para planejamento, execucao e validacao

## Fluxo alvo

O fluxo principal continua sendo:

1. `Claude` planeja
2. `Codex` executa por padrao
3. `Claude` valida quando o risco justificar

O orquestrador agora tambem suporta o experimento:

1. `Claude Opus` escreve a arquitetura
2. `Claude Sonnet` ou `Codex` implementa
3. `Claude` valida no final

## Componentes implementados

### 1. Hub e painel

- `manage-skills.ps1`
  - backend da UI
  - endpoints do painel `/claude-auth`
  - instalacao do coletor de uso
  - adicao de perfis Claude ate o limite de 10
- `ui/claude-auth.html`
  - login por perfil
  - exibicao do link OAuth
  - instalacao da coleta
  - metricas oficiais do ultimo snapshot
  - agregados locais por periodo e por modelo
- `abrir-painel-claude-auth.bat`
  - launcher de dois cliques para abrir direto no painel certo

### 2. Orquestrador

- `all-skills/orchestrate/scripts/run_ai_cli.py`
  - descoberta dos CLIs
  - suporte a `--model` no Claude
- `all-skills/orchestrate/scripts/claude_codex_orchestrator.py`
  - perfis Claude isolados por `CLAUDE_CONFIG_DIR`
  - failover reativo
  - selecao de modelo por etapa
  - executor alternando entre `codex` e `claude`
- `all-skills/orchestrate/scripts/claude_codex_orchestrator.ps1`
  - wrapper PowerShell

### 3. Coleta de uso

- `all-skills/orchestrate/scripts/claude_statusline_collector.py`
  - parser do payload `statusLine`
  - persistencia de snapshots por perfil e sessao
- `all-skills/orchestrate/scripts/claude_statusline_collector.ps1`
  - wrapper PowerShell chamado pelo Claude
- instalacao real fora do repositorio em:
  - `%USERPROFILE%\.claude-orchestrator\statusline-tools\`
  - `%USERPROFILE%\.claude-orchestrator\usage\`

## Estrutura fora do repositorio

```text
%USERPROFILE%\.claude-orchestrator\
|-- config.json
|-- state.json
|-- statusline-tools\
|   |-- claude_statusline_collector.ps1
|   `-- claude_statusline_collector.py
`-- usage\
    `-- profiles\
        `-- claude-a\
            |-- latest.json
            `-- sessions\

%USERPROFILE%\.claude-profiles\
|-- claude-a\
|-- claude-b\
|-- claude-c\
`-- ... ate claude-j
```

## Limites e regras de perfis

- limite atual: `10` perfis
- nomes reservados: `claude-a` ate `claude-j`
- criacao incremental pelo painel ou por CLI
- novos perfis herdam `settings.json` e `trustedFolders.json` do perfil base, quando existir
- a coleta e reinstalada automaticamente para o nome correto do perfil novo

## Painel `/claude-auth`

### O que ele faz

- lista todos os perfis do orquestrador
- mostra status de login por perfil
- gera o fluxo `auth login` e captura a URL OAuth
- permite copiar ou abrir o link
- instala o coletor de uso
- mostra metricas de uso com separacao entre dado oficial e agregado local

### O que aparece como oficial

Vindo do payload real do `statusLine` do Claude:

- modelo da sessao
- custo total da sessao
- duracao total e duracao de API
- tokens de entrada e saida
- cache write e cache read
- contexto usado
- `5h` usado e horario de reset
- `7d` usado e horario de reset

### O que aparece como agregado local

Calculado a partir dos snapshots observados neste computador:

- custo por `5h local`
- custo por `dia`
- custo por `semana`
- sessoes por modelo
- tokens por modelo
- tempo por modelo
- total observado de `Opus` na semana

## Comandos principais

### Abrir o painel

```powershell
.\abrir-painel-claude-auth.bat
```

### Adicionar um perfil novo

```powershell
.\manage-skills.ps1 add-claude-profile
```

### Instalar ou reinstalar a coleta

```powershell
.\manage-skills.ps1 sync-claude-usage-collector -Force
```

### Planejar com Opus

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py call-claude --model opus --prompt "planeje a arquitetura"
```

### Fluxo Opus -> Sonnet -> Claude

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py route `
  --task "implemente X" `
  --working-dir C:\repo `
  --planner-model opus `
  --executor-provider claude `
  --executor-model sonnet `
  --validation-model sonnet
```

## Bug importante corrigido

### Sintoma

Ao clicar em `Iniciar Login`, nenhuma URL aparecia no painel.

### Causa raiz

O `statusLine` apontava para um comando localizado dentro de `AI Skills Hub`, e o caminho com espacos quebrava a execucao do processo antes do `auth login`.

### Correcao aplicada

- os scripts do coletor foram copiados para `%USERPROFILE%\.claude-orchestrator\statusline-tools\`
- o estado do coletor foi movido para `%USERPROFILE%\.claude-orchestrator\usage\`
- os `settings.json` dos perfis foram regravados para apontar para esse caminho sem espacos
- o painel passou a exibir falha de login em destaque quando ocorrer

## Validacoes realizadas

- `python -m py_compile` nos scripts principais
- `python -m unittest` para:
  - `test_claude_codex_orchestrator.py`
  - `test_claude_statusline_collector.py`
  - `test_run_ai_cli.py`
- smoke test do coletor via `statusLine`
- teste real de `claude auth login`, confirmando emissao da URL OAuth
- criacao real do perfil `claude-c`

## O que ainda depende do usuario

- autenticar os perfis desejados no painel
- repetir o login para qualquer perfil novo criado
- no computador de casa, ajustar caminhos locais se eles diferirem do notebook atual

## Integracao com VPS OpenClaw (19/04/2026)

O painel agora propaga o login Claude/Codex do profile ativo para o OpenClaw na VPS `79.72.71.20` automaticamente:

- Hooks em `manage-skills.ps1`:
  - `Get-ClaudeAuthLoginSession`: dispara sync quando `loginSucceeded=true` **e** o profile que logou e o ativo (evita sobrescrever a VPS com profile so preparado).
  - `POST /api/claude-auth/set-active`: dispara sync do novo ativo.
  - `Get-CodexAuthLoginSession`: dispara sync quando login Codex conclui (usa o Claude ativo + `~/.codex/auth.json` atual).
  - `POST /api/codex-auth/set-active`: dispara sync apos `Set-CodexProfileJunction`.
- Endpoints novos:
  - `POST /api/claude-auth/sync-vps` (body `{profile?}`): forca sync manual.
  - `GET /api/claude-auth/vps-sync-status`: ultimo resultado por profile para a UI.
- UI (`ui/claude-auth.html`):
  - Selo `VPS OK / atualizado / stale / skip / erro` no header de cada card Claude.
  - Botao `Sync VPS` na linha de botoes de cada card.
- Script chamado por baixo: `C:\Users\marce\Diego\VPS\Oracle\ClowdBot\scripts\vps_ai_auth_sync.py` com `--claude-source <profile_dir>`.
- Status persistido em `%USERPROFILE%\.claude-orchestrator\vps-sync-status.json`.
- Flag anti-reentrancia: `<session>\vps-synced.flag` em cada sessao de login.

Runbook completo (arquitetura, fluxos, diagnostico, troubleshooting, rollback): `C:\Users\marce\Diego\VPS\Oracle\ClowdBot\docs\operacional\VPS_AUTH_SYNC.md`.

Changelog da entrega: `C:\Users\marce\Diego\VPS\Oracle\ClowdBot\docs\changelog\CHANGELOG_2026-04-19.md`.

## Restauracao em outra maquina

Para levar para outra maquina:

1. copie os arquivos do pacote
2. abra o projeto
3. execute `abrir-painel-claude-auth.bat`
4. se necessario, rode `.\manage-skills.ps1 sync-claude-usage-collector -Force`
5. crie os perfis adicionais com `Adicionar Perfil`
6. autentique cada conta pelo painel
