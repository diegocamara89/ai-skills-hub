# AI Skills Hub

Hub central para manter um catalogo unico de skills e sincroniza-las para Claude, Codex, Qwen e Antigravity. Suporte a Gemini em desenvolvimento.

## Estrutura

```text
AI-Skills-Hub/
|-- all-skills/              # fonte da verdade
|-- global-skills/           # conjunto global legado
|-- ui/                      # interface web
|-- manage-skills.ps1        # backend + CLI
|-- skill-manager.bat        # launcher da UI
|-- backups/                 # backups de seguranca
`-- state/                   # estado local e checkouts auxiliares
```

## Uso rapido

```powershell
# Ver o estado geral
.\manage-skills.ps1 status

# Ativar skills globais
.\manage-skills.ps1 enable-global -Skills napkin,doc,orchestrate
.\manage-skills.ps1 reconcile

# Sincronizar superpowers pelo fluxo nativo
.\manage-skills.ps1 sync-native-superpowers
.\manage-skills.ps1 sync-native-superpowers -Install -Force

# Instalar o coletor de uso do Claude nos perfis
.\manage-skills.ps1 sync-claude-usage-collector -Force
```

## UI

1. Execute `skill-manager.bat`.
2. Abra `http://localhost:8765`.
3. Marque em quais agentes cada skill deve ficar instalada.

O backend ja diferencia instalacoes gerenciadas de instalacoes nativas.

### Painel Claude Auth

Abra com `abrir-painel-claude-auth.bat` (porta 8766). Centraliza:

- troca de perfil ativo com hot-swap (sem fechar o Claude Code)
- autenticacao OAuth por perfil com links de login
- status de uso (`5h`, `7d`, reset, custo, tokens) com barras de progresso
- badge "EM USO" no perfil realmente ativo (detectado via resolucao da junction)
- abas: **Claude** | **Codex/OpenAI** | **Gemini/Google** (em breve)
- sub-abas dentro de Claude: Perfis | Status | Configuracoes
- sub-abas dentro de Codex: Perfis | Status

Fluxo recomendado para uso humano:

1. abra `abrir-painel-claude-auth.bat`
2. clique em `Iniciar Login` no perfil desejado
3. copie ou abra o link OAuth
4. para trocar de perfil durante uma conversa: clique em `Ativar` — a troca e imediata via junction

### Painel Codex

O painel Codex (aba **Codex/OpenAI**) permite:

- listar perfis Codex com status de uso (barras 5h e 7d)
- trocar de conta ativa sem perder sessoes, historico ou threads
- iniciar login de nova conta via terminal externo (`codex login`)
- exibir ultimo uso por perfil e timestamp de atualizacao dos dados

**Arquitetura de multi-perfil Codex:**

```
~/.codex/                      # diretorio compartilhado (sessions, history, state_5.sqlite)
  auth.json                    # UNICO arquivo trocado na mudanca de perfil
  sessions/                    # todas as conversas — compartilhadas entre perfis
  history.jsonl                # historico global
  state_5.sqlite               # 900+ threads SQLite

~/.codex-profiles/
  codex-a/
    auth.json                  # credenciais da conta A (copiado para ~/.codex ao ativar)
  codex-b/
    auth.json                  # credenciais da conta B
  active -> ~/.codex           # junction FIXA (nunca muda de destino)

~/.codex-active-profile        # marker com nome do perfil ativo (ex: "codex-a")
```

Ao trocar de perfil, apenas `auth.json` e substituido em `~/.codex`. Todas as sessoes,
historico e threads permanecem intactos — identico ao comportamento nativo do Codex CLI
ao trocar de conta pela propria interface.

**Dados de uso** sao lidos dos arquivos JSONL de sessao em `~/.codex/sessions/` — eventos
`token_count` com `rate_limits.primary` (5h) e `rate_limits.secondary` (7d).

### Rotacao Automatica de Perfis (auto-rotate)

O sistema troca de perfil automaticamente quando o uso atinge 95% do limite (5h ou 7d).

#### Claude

**Arquitetura — Junction `active`:**

```
CLAUDE_CONFIG_DIR (fixo) → %USERPROFILE%\.claude-profiles\active\  (junction)
                                          ↓
                           %USERPROFILE%\.claude-profiles\claude-a\  (perfil real)
```

Ao trocar de perfil, o destino da junction e atualizado para apontar para o proximo perfil.
O processo Claude Code em execucao le as credenciais do novo perfil na proxima chamada de API
— sem precisar reiniciar.

**Componentes:**

- `auto-rotate.ps1` — verifica uso e recria a junction para o proximo perfil disponivel
- `ClaudeAutoRotate` (Task Scheduler) — executa a cada 10 min, invisivel (`LogonType: S4U`)
- `manage-skills.ps1 → Set-ClaudeProfileJunction` — funcao usada pelo painel e pelo auto-rotate
- `~/.claude-active-dir` — marker sem BOM lido pelo PowerShell profile em novos terminais

**Para forcar rotacao manualmente:**

```powershell
.\auto-rotate.ps1 -Force
```

**Para recriar a junction apos reinstalacao:**

```powershell
# Bootstrap inicial (apenas uma vez)
$activeLink = "$env:USERPROFILE\.claude-profiles\active"
New-Item -ItemType Junction -Path $activeLink -Target "$env:USERPROFILE\.claude-profiles\claude-a"
[System.Environment]::SetEnvironmentVariable("CLAUDE_CONFIG_DIR", $activeLink, "User")
```

#### Codex

**Arquitetura — Auth-only swap:**

```
~/.codex-profiles/active  →  ~/.codex   (junction FIXA — nunca muda)
```

Ao trocar de perfil Codex, apenas `auth.json` e substituido. A junction permanece apontando
para `~/.codex` — sessions e historico nunca sao movidos.

**Componentes:**

- `auto-rotate-codex.ps1` — verifica uso via JSONL de sessao e substitui auth.json
- `CodexAutoRotate` (Task Scheduler) — executa a cada 10 min, invisivel
- `manage-skills.ps1 → Set-CodexProfileJunction` — funcao de troca de perfil
- `~/.codex-active-profile` — marker com nome do perfil ativo

**Dados de uso lidos de:**

```
~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
  → evento token_count → payload.rate_limits.primary   (janela 5h)
  → evento token_count → payload.rate_limits.secondary  (janela 7d)
```

**Para forcar rotacao manualmente:**

```powershell
.\auto-rotate-codex.ps1 -Force
```

## Setup inicial

### Requisitos

- Windows 10/11
- PowerShell 5.1+
- Claude Code CLI instalado
- Codex CLI instalado (opcional, para aba Codex)
- Node.js (para `codex-companion.mjs`)

### Primeiro uso

```powershell
# 1. Criar junction do Claude (uma vez)
$activeLink = "$env:USERPROFILE\.claude-profiles\active"
New-Item -ItemType Junction -Path $activeLink -Target "$env:USERPROFILE\.claude-profiles\claude-a"
[System.Environment]::SetEnvironmentVariable("CLAUDE_CONFIG_DIR", $activeLink, "User")

# 2. Criar estrutura Codex (uma vez)
$codexProfiles = "$env:USERPROFILE\.codex-profiles"
New-Item -ItemType Directory -Path "$codexProfiles\codex-a" -Force
# junction ativa aponta para ~/.codex (compartilhado)
New-Item -ItemType Junction -Path "$codexProfiles\active" -Target "$env:USERPROFILE\.codex"
# copiar auth atual para o perfil
Copy-Item "$env:USERPROFILE\.codex\auth.json" "$codexProfiles\codex-a\auth.json"
"codex-a" | Set-Content "$env:USERPROFILE\.codex-active-profile" -NoNewline

# 3. Iniciar o painel
.\abrir-painel-claude-auth.bat
```

### Registrar tarefas agendadas (auto-rotate)

```powershell
# Claude auto-rotate (a cada 10 min)
$action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -File `"$PWD\auto-rotate.ps1`""
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 10) -Once -At (Get-Date)
Register-ScheduledTask -TaskName "ClaudeAutoRotate" -Action $action -Trigger $trigger -RunLevel Limited

# Codex auto-rotate (a cada 10 min)
$action2 = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NonInteractive -File `"$PWD\auto-rotate-codex.ps1`""
Register-ScheduledTask -TaskName "CodexAutoRotate" -Action $action2 -Trigger $trigger -RunLevel Limited
```

## Directorios alvo

- Claude: `%USERPROFILE%\.claude\skills`
- Codex legacy: `%USERPROFILE%\.codex\skills`
- Codex user: `%USERPROFILE%\.agents\skills`
- Qwen: `%USERPROFILE%\.qwen\skills`
- Antigravity: `%USERPROFILE%\.antigravity\skills`
- Gemini: `%USERPROFILE%\.gemini\antigravity\skills` para legado reconstruido e `%USERPROFILE%\.gemini\extensions` para extensoes nativas _(suporte em desenvolvimento)_

## Importacao GitHub

O importador GitHub agora aceita apenas repositorios que tenham `SKILL.md` na raiz.

Ele rejeita:

- pacotes multi-skill
- extensoes nativas
- repositorios sem `SKILL.md` raiz

Isso evita o problema de importar algo como `superpowers` como se fosse uma skill unica quebrada.

## Integracoes nativas

Pacotes como `superpowers` devem ser tratados por mecanismo nativo do agente:

- Claude: marketplace ou plugin oficial
- Codex: skill packs sincronizados para os diretorios nativos
- Gemini: `extensions link` ou `extensions install` _(em desenvolvimento)_

O comando `sync-native-superpowers` centraliza esse fluxo no hub.

## Orquestracao Claude + Codex

A skill [`orchestrate`](./all-skills/orchestrate/SKILL.md) foi atualizada para o fluxo:

- Claude planeja
- Codex executa
- Claude valida quando necessario

Ela inclui:

- wrapper Windows para perfis Claude com `CLAUDE_CONFIG_DIR`
- failover reativo por cota
- handoff estruturado de baixo contexto
- selecao explicita de modelo para planejamento, execucao e validacao
- suporte a ate `10` perfis Claude no mesmo usuario
- painel de login e uso com observabilidade local
- documentacao de instalacao nativa

Detalhamento completo em `all-skills/orchestrate/references/claude-auth-control-plane.md`.

## Dicas

- Edite skills sempre em `all-skills/`, nunca direto no destino nativo se ele for junction.
- Use `reconcile` depois de alterar selecao global ou estado gerenciado.
- Para PowerShell com politica restritiva, prefira `powershell -ExecutionPolicy Bypass -File ...` ao rodar wrappers `.ps1`.
