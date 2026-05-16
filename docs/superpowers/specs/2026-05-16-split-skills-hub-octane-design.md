# Split `AI-Skills-Hub` → `ai-skills-hub` + `octane` — Design Spec

**Data:** 2026-05-16
**Autor:** Marcelo (Diego) + Claude (brainstorming session)
**Status:** Aprovado para writing-plans

---

## 1. Contexto e motivação

A pasta `C:\Users\marce\Diego\AI-Skills-Hub` evoluiu para conter **dois sistemas distintos** misturados:

1. **AI Skills Hub** — gerencia 45 skills (`all-skills/`), sincroniza junctions NTFS para Claude/Codex/Qwen/Antigravity/Gemini. UI web na porta 8765.
2. **Claude Auth Manager** (a renomear para **octane**) — multi-profile manager para Claude/Codex/Gemini, hot-swap de credenciais via junction, auto-rotate por uso (95%), OAuth, usage tracking 5h/7d, VPS sync. UI web na porta 8766.

O monolito real é o `manage-skills.ps1` (5886 linhas) que mistura ambos. Existe uma pasta `aiox-shared/` com 9 módulos `.psm1` resíduo de plano anterior parcialmente executado (`docs/superpowers/plans/2026-05-10-evolution-d.md`).

**Repo GitHub atual:** `diegocamara89/ai-skills-hub`. A pasta local **não é git** ainda — primeiro commit acontecerá na Fase 0.

## 2. Objetivos e não-objetivos

### Objetivos

- Dois repositórios GitHub independentes, sem dependência cruzada de código.
- Cada repo é instalável e usável isoladamente.
- Refatorar `manage-skills.ps1` em módulos `.psm1` reutilizáveis por três interfaces (HTTP, CLI por flags, TUI Spectre.Console).
- **Zero perda de perfis configurados** durante a migração.
- CLI standalone (não precisa de servidor HTTP rodando) + TUI (Spectre.Console) + Web UI (continua existindo, refinada).

### Não-objetivos

- Reescrita lógica das features existentes (auto-rotate, OAuth, junction swap, sync de skills). Tudo continua funcionando como hoje, só muda de pasta.
- Migrar `aiox-shared/` para terceiro repo. Vai ser **dissolvido** durante a Fase 2.
- Preservar histórico git (o repo local nem é git ainda — primeira história começa na Fase 0).
- Suporte oficial a Qwen no octane (estrutura comporta, mas não testado nesta iteração).
- Migração de Web UI para framework moderno (continua HTML/JS vanilla).
- Cross-platform (continua Windows-first).
- **Fixar o bug de rate limits do Codex** (perfil A reflete em todos) — vira primeira issue pós-split, em código já isolado e testável.

## 3. Decisões consolidadas

| Item | Decisão |
|------|---------|
| Repo Skills Hub | `diegocamara89/ai-skills-hub` (existente, continua) |
| Repo Auth | `diegocamara89/octane` (novo) |
| Utilitários PowerShell compartilhados | Duplicados em cada repo (sem terceiro repo, sem submodule) |
| `aiox-shared/` | Dissolvido na Fase 2: `StructuredLogger.psm1` e `CliRuntime.psm1` duplicados nos dois; resto vai só para `octane` |
| Estratégia de split | Abordagem A — 5 fases com rede de segurança |
| Histórico git preservado | Não — primeiro commit do projeto acontece na Fase 0 |
| CLI standalone (sem HTTP) | Sim — entra neste mesmo split |
| TUI | Spectre.Console (.NET) — dependência ~10MB DLL |
| CLI binary `octane` | Verbos padrão + namespacing por engine (estilo `gh pr list`) |
| CLI binary Hub | `ai-skills` (mantido, com refresh leve) |
| Auto-rotate default no octane | **Desligado**. Usuário liga via `octane auto-rotate on` quando confortável |
| Setup | Dois `setup.ps1` (um por repo) + `setup-all.ps1` orquestrador fino no Hub |

## 4. Estrutura final dos dois repos

### Repo `ai-skills-hub` (existente, refatorado)

```
~/Diego/ai-skills-hub/
  README.md
  LICENSE
  .gitignore
  setup.ps1                                 # setup só-Hub
  setup-all.ps1                             # orquestrador (chama setup do octane primeiro, depois o próprio)
  skills.cmd                                # shim local para CLI
  ai-skills.ps1                             # CLI standalone (flag mode)
  ai-skills-tui.ps1                         # TUI (Spectre.Console)
  modules/
    SkillManager.psm1                       # lógica core (extraída do monolito)
    Common.psm1                             # Set-FileAtomic, Ensure-Junction, Write-Utf8File, etc. (duplicado)
    StructuredLogger.psm1                   # duplicado de aiox-shared
    CliRuntime.psm1                         # duplicado de aiox-shared (usado por sync de skills Codex/Gemini)
    FrontmatterValidator.psm1               # renomeado de lib/frontmatter-validator.ps1
    SkillLockfile.psm1                      # renomeado de lib/skill-lockfile.ps1
    UpstreamImporter.psm1                   # renomeado de lib/upstream-importer.ps1
  server/
    Start-SkillManagerUI.ps1                # HTTP handler (porta 8765)
  ui/
    index.html                              # Web UI Skills (era ui/index.html)
  all-skills/                               # 45 skills (mantido como está)
  global-skills/                            # junctions legadas (mantido)
  state/
    superpowers/                            # state da sync nativa de superpowers
    managed-targets.json                    # caminhos atualizados pós-split
  tests/                                    # Pester só-Hub
    SkillManager.Tests.ps1                  # novo, extraído
    FrontmatterValidator.Tests.ps1
    SkillLockfile.Tests.ps1
    UpstreamImporter.Tests.ps1
    CodexSkillSync.Tests.ps1                # cenário extraído do mestiço RemoveProfilesAndCodexSync
```

### Repo `octane` (novo)

```
~/Diego/octane/
  README.md
  LICENSE
  .gitignore
  setup.ps1                                 # setup só-Octane (Task Scheduler, junctions de perfil, env vars)
  octane.cmd                                # shim local para CLI
  octane.ps1                                # CLI standalone (flag mode)
  octane-tui.ps1                            # TUI (Spectre.Console)
  modules/
    Octane.psm1                             # módulo principal — re-export dos submódulos abaixo
    ClaudeAuth.psm1                         # perfis Claude, hot-swap junction
    CodexAuth.psm1                          # perfis Codex, auth.json swap
    GeminiAuth.psm1                         # perfis Gemini (suporte em desenvolvimento)
    AutoRotate.psm1                         # lógica core do auto-rotate
    UsageTracker.psm1                       # uso 5h/7d (Claude estimate + Codex JSONL)
    OAuthRefresh.psm1                       # renomeado de lib/oauth-refresh.ps1
    VpsSync.psm1                            # extraído de manage-skills.ps1 (Invoke-VpsAuthSync*)
    Common.psm1                             # duplicado (Set-FileAtomic etc.)
    StructuredLogger.psm1                   # duplicado de aiox-shared
    CliRuntime.psm1                         # duplicado de aiox-shared
    Mutex.psm1                              # auth-only (junction swap locking)
    HealthMonitor.psm1                      # auth-only
    Health.psm1                             # auth-only
    Alerting.psm1                           # auth-only
    VpsAuthHealth.psm1                      # auth-only
    Cleanup.psm1                            # auth-only
  bin/
    auto-rotate.ps1                         # executado pelo Task Scheduler
    auto-rotate-codex.ps1
    auto-rotate-gemini.ps1
  server/
    Start-OctaneUI.ps1                      # HTTP handler (porta 8766)
  ui/
    index.html                              # Web UI octane (era ui/claude-auth.html)
  tests/
    AuthLoginUrls.Tests.ps1
    AutoRotate.Tests.ps1                    # consolidado de AutoRotateBugs/Cli/Toggle
    OAuthRefresh.Tests.ps1
    JunctionResolution.Tests.ps1
    ProfileCrud.Tests.ps1                   # cenário de perfil extraído de RemoveProfilesAndCodexSync
    GeminiAuth.Tests.ps1
    VpsAuthSync.Tests.ps1
    RollbackOnFailure.Tests.ps1
    UsageTracker.Tests.ps1                  # novo — captura o bug de rate limits cruzando
```

## 5. Regra de propriedade exclusiva (contrato de segurança)

**Regra dura:** cada repo só escreve nos seus próprios recursos em disco. **Sem exceção.**

| Recurso em disco | Owner |
|------------------|-------|
| `~\.claude-profiles\` + junction `active` | **octane** |
| `~\.codex-profiles\` + junction `active` | **octane** |
| `~\.codex\` (sessions, history, state SQLite) | **octane** (gerencia `auth.json`) |
| Env vars `CLAUDE_CONFIG_DIR`, `CODEX_HOME` | **octane** |
| Markers `~\.claude-active-dir`, `~\.codex-active-profile` | **octane** |
| Task Scheduler `ClaudeAutoRotate`, `CodexAutoRotate` | **octane** |
| Junctions skills `~\.claude\skills\` | **ai-skills-hub** |
| Junctions skills `~\.codex\skills\`, `~\.agents\skills\` | **ai-skills-hub** |
| Junctions skills `~\.qwen\skills\`, `~\.antigravity\skills\`, `~\.gemini\*\skills\` | **ai-skills-hub** |
| Shim `~\.local\bin\octane.cmd` | **octane** |
| Shim `~\.local\bin\ai-skills.cmd` | **ai-skills-hub** |

**Implicação:** se algum script do Hub precisar saber "qual perfil está ativo", ele **lê** (não escreve) o marker do octane. Hub jamais cria, modifica ou deleta nada de perfil. octane jamais cria, modifica ou deleta nada de skill.

## 6. Arquitetura de módulo + 3 interfaces

Cada repo segue o mesmo padrão:

```
         ┌──────────────────────────────┐
         │  Módulo central (.psm1)      │
         │  Lógica de negócio pura      │
         │  Retorna objetos PS, joga    │
         │  erros. Não conhece HTTP,    │
         │  terminal ou TUI.            │
         └──────────────┬───────────────┘
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
       *.ps1       *-tui.ps1    Start-*UI.ps1
       (flag CLI)  (Spectre TUI)  (HTTP server)
          │             │             │
          ▼             ▼             ▼
       terminal     terminal       browser
```

### Implicações

- Funções de negócio aceitam parâmetros, retornam objetos PowerShell, lançam erros. **Não sabem nada sobre HTTP, terminal ou TUI.**
- HTTP handler serializa para JSON.
- CLI flag formata para terminal text.
- TUI desenha tabela Spectre.Console.
- **CLI funciona sem servidor HTTP rodando** — resolve a fragilidade atual.

## 7. Superfície de comandos

### `octane` (auth/profile management)

```text
# Interativo
octane                                # abre TUI Spectre

# Visão geral
octane status                         # uso 5h/7d todas engines + processos rodando
octane engines                        # lista CLIs rodando + PID + perfil de cada

# Perfis (CRUD + switch)
octane list                           # todos os perfis de todas engines
octane claude list                    # só Claude
octane codex list                     # só Codex
octane gemini list                    # só Gemini
octane switch <perfil> [--force]      # troca perfil ativo (auto-detecta engine pelo prefixo do nome)
octane claude switch <perfil>         # explícito por engine
octane add <perfil> [--engine X]      # cria slot de perfil novo
octane remove <perfil> [--engine X]   # remove perfil
octane login <perfil>                 # inicia OAuth, devolve URL

# Auto-rotate
octane rotate [engine] [--force]      # força rotação manual (pit stop)
octane auto-rotate on|off|status      # liga/desliga task scheduler

# VPS sync
octane vps push [--engine X]          # empurra credenciais do perfil ativo para VPS
octane vps status                     # último sync por engine: ok/erro/timestamp
octane vps restart                    # reinicia gateway no VPS

# Manutenção
octane backup [--out <pasta>]         # snapshot de todos os perfis
octane restore <backup>               # restaura snapshot
octane doctor                         # diagnóstico (junctions, env vars, task scheduler, markers)
octane panel                          # abre web UI (porta 8766) no browser
```

### TUI `octane` — esboço de tela (Spectre.Console)

```
┌─ octane ─────────────────────────────── auto-rotate: ON ─┐
│                                                          │
│  CLAUDE                                                  │
│  ▸ claude-a    [████████░░] 80% 5h │ [█████░░░░░] 50% 7d │
│    claude-b    [██░░░░░░░░] 20% 5h │ [█░░░░░░░░░] 10% 7d │
│    claude-c    [empty]                                   │
│                                                          │
│  CODEX                                                   │
│  ▸ codex-a     [██████████] 99% 5h │ [████████░░] 80% 7d │ ⚠
│    codex-b     [░░░░░░░░░░]  0% 5h │ [░░░░░░░░░░]  0% 7d │
│                                                          │
│  GEMINI                                                  │
│    (em desenvolvimento)                                  │
│                                                          │
├──────────────────────────────────────────────────────────┤
│  ↑↓ navegar  ENTER switch  L login  R rotate  Q sair     │
└──────────────────────────────────────────────────────────┘
```

Teclas:
- `↑↓` navega perfis (cross-engine).
- `ENTER` switch para perfil selecionado (com confirmação modal).
- `L` inicia OAuth login para perfil selecionado.
- `R` força rotate (pit stop) para perfil selecionado.
- `A` toggle auto-rotate global.
- `V` push VPS sync do perfil ativo.
- `D` doctor (diagnóstico).
- `Q` sair.

### `ai-skills` (skills management)

```text
# Interativo
ai-skills                             # abre TUI Spectre

# Skills
ai-skills list [--global|--project]
ai-skills enable <skill> [--targets claude,codex,gemini,qwen,antigravity]
ai-skills disable <skill>
ai-skills reconcile                   # recria junctions a partir do estado JSON
ai-skills import <github-url|path>    # importa skill nova (rejeita pacotes multi-skill)
ai-skills sync-native superpowers     # sincroniza plugin nativo (superpowers etc.)

# Manutenção
ai-skills doctor                      # checa junctions de skills + frontmatter
ai-skills panel                       # abre web UI (porta 8765) no browser
```

## 8. Fases de migração

### Fase 0 — Rede de segurança (1h)

- `git init` em `C:\Users\marce\Diego\AI-Skills-Hub`.
- Commit "v1 monolítica pré-split" com tudo (incluindo `tmp-*/` por enquanto — vão ser removidos depois pelo `.gitignore`).
- Push para branch `archive/monolith-v1` no `diegocamara89/ai-skills-hub`.
- **Snapshot dos perfis:** `robocopy /MIR` de `~\.claude-profiles\`, `~\.codex-profiles\`, `~\.codex\` para `~\.profile-backups\2026-05-16-<hhmm>-fase0\`.
- Lista junctions vigentes com `Get-Item` em `cutover-pre-fase0.txt`.

**Critério para sair da fase:** branch `archive/monolith-v1` existe no GitHub, snapshot existe em `~\.profile-backups\`.

### Fase 1 — Refatorar monolito no mesmo workspace (3–4h)

- Cria `modules-skills/` e `modules-octane/` lado a lado dentro do projeto atual (subdiretórios temporários). Na Fase 2 esses viram `modules/` dentro de cada repo novo.
- Extrai funções do `manage-skills.ps1` em `.psm1` por fronteira (sem mover pastas ainda). Classificação por nome de função (não por número de linha — funções estão dispersas):
  - **octane:** `Set-ClaudeProfileJunction`, `Set-CodexProfileJunction`, `Get-Claude*`, `Get-Codex*`, `Get-Gemini*`, `Add-ClaudeProfile`, `Add-CodexProfile`, `Add-GeminiProfile`, `Remove-*Profile`, `Invoke-ClaudeAuthCommand`, `*-OAuth*`, `*-AuthLoginSession`, `Get-*UsageProfile*`, `Get-*RateLimits`, `Invoke-VpsAuthSync*`, `Get-RunningInstances`, `Start-ClaudeAuthUI`, etc.
  - **hub:** `Sync-NativeSuperpowers`, `Enable-GlobalSkills`, `Disable-GlobalSkills`, `Sync-GlobalSkills`, `Sync-LegacyGeminiSkills`, `Add-ProjectSkills`, `Remove-ProjectSkills`, `Sync-ProjectSkills`, `Import-ExistingSkills`, `Reconcile-SharedSkills`, `Ensure-GeminiImportBlock`, `Write-GeminiGeneratedFile`, `Update-ClaudeDesktopTrustedFolders`, `Start-SkillManagerUI`, `Show-Status`, `Show-Help`, etc.
  - **common (duplicado):** `Set-FileAtomic`, `Set-JsonFileAtomic`, `Write-Utf8File`, `Write-JsonFile`, `Normalize-FullPath`, `Join-UserProfilePath`, `Ensure-Directory`, `Ensure-Junction`, `Get-RuntimeInfo`, `Write-Step`, `Set-NoCacheHeaders`.
- Cria `skill-manager.ps1` e `octane-monolith.ps1` no root, cada um importa seu módulo + roda seu HTTP handler.
- **Atualiza imports** em `auto-rotate*.ps1`, `lib/*.ps1`, testes.
- Roda **todos os Pester atuais** (`tests/` + `aiox-shared/tests/`). Tem que passar 100% antes de seguir.
- Commit "fase 1: monolito quebrado em módulos, workspace inalterado".

**Critério para sair da fase:** `Invoke-Pester C:\Users\marce\Diego\AI-Skills-Hub\tests, C:\Users\marce\Diego\AI-Skills-Hub\aiox-shared\tests` → 100% pass.

### Fase 2 — Separação física em duas pastas (2h)

- Cria `~\Diego\ai-skills-hub\` e `~\Diego\octane\` paralelas (não dentro do projeto antigo).
- Move arquivos conforme §4. Dissolve `aiox-shared/`:
  - `StructuredLogger.psm1`, `CliRuntime.psm1` → duplicados nos dois repos.
  - `Mutex.psm1`, `HealthMonitor.psm1`, `Health.psm1`, `Alerting.psm1`, `VpsAuthHealth.psm1`, `Cleanup.psm1`, `Aiox.psm1` → só `octane`.
- Atualiza imports dentro de cada pasta (paths relativos a `$PSScriptRoot`).
- Roda Pester de cada pasta isoladamente. Tem que passar.
- Atualiza `ai-skills-hub/state/managed-targets.json` para apontar para novos caminhos.

**Critério para sair da fase:** Pester passa em ambas as pastas; junctions de skills no `~\.claude\skills\` etc. ainda apontam para os caminhos antigos (não foram tocadas — isso muda na Fase 4).

### Fase 3 — Git/GitHub split (1h)

- `git init` em `~\Diego\ai-skills-hub\` e `~\Diego\octane\`.
- Primeiro commit limpo em cada (`.gitignore` exclui `tmp-*/`, `backups/`, `state/native-integrations/superpowers/checkout/`, `exports/`).
- **Hub:** `git remote add origin git@github.com:diegocamara89/ai-skills-hub.git`. Como o GitHub `main` atual reflete o monolito antigo (já preservado em `archive/monolith-v1` na Fase 0), **force push `main`** com o conteúdo split. Confirmar antes que `archive/monolith-v1` existe no remoto.
- **Octane:** cria repo `diegocamara89/octane` no GitHub (privacidade igual ao Hub atual). `git remote add origin git@github.com:diegocamara89/octane.git`. Push normal de `main` (repo vazio, sem conflito).

**Critério para sair da fase:** `git status` limpo nos dois; ambos visíveis no GitHub.

### Fase 3.5 — Pré-cutover (15min)

- **Segundo snapshot** dos perfis: `robocopy /MIR ... ~\.profile-backups\2026-05-16-<hhmm>-fase35\`. Imediatamente antes do cutover.
- Lista todas as junctions vigentes em `cutover-pre-fase35.txt`. Comparar com `cutover-pre-fase0.txt` — devem ser idênticas (Fases 1–3 não tocam disco fora do projeto).
- Roda `octane doctor` (do novo repo). Deve passar todas as checagens.

**Critério para sair da fase:** `octane doctor` passa; snapshot Fase 3.5 idêntico ao Fase 0 (perfis intocados).

### Fase 4 — Cutover atômico do Task Scheduler (30min)

- Registra **novas** tasks `ClaudeAutoRotate-v2` e `CodexAutoRotate-v2` apontando para `~\Diego\octane\bin\auto-rotate*.ps1` (nomes com `-v2` para coexistir temporariamente sem conflito).
- Executa cada task nova **manualmente uma vez** (`-Force`). Verifica `Get-StructuredLog` que rodou e não quebrou nada.
- **Desabilita** (não remove) as tasks antigas `ClaudeAutoRotate` e `CodexAutoRotate`.
- Aguarda **15 min**, observa logs. Auto-rotate continua funcionando? Verifica que `-v2` rodou e a antiga não.
- Renomeia: remove tasks antigas (já desabilitadas), renomeia `-v2` para `ClaudeAutoRotate`/`CodexAutoRotate`.
- **Não pode haver janela com duas tasks ativas escrevendo na mesma junction.**

**Critério para sair da fase:** apenas as tasks novas existem e estão funcionais. Task antigas removidas. Junction `~\.claude-profiles\active` aponta para o mesmo destino que apontava antes da Fase 4.

### Fase 5 — Validação em uso real + arquivamento (30min)

- Cria shims `~\.local\bin\octane.cmd` e atualiza `~\.local\bin\ai-skills.cmd` para apontar para os novos caminhos.
- Abre painel octane (8766) e painel skills hub (8765). Ambos carregam.
- Em conversa Claude Code ativa: `octane switch <outro-perfil>` → confirma diálogo modal → próxima chamada API usa novo perfil. Junction destino mudou.
- `octane status` lista uso 5h/7d corretamente.
- `ai-skills list` lista skills corretamente.
- `ai-skills reconcile` reconstrói junctions de skills, todas apontam para novo Hub path.
- Move `~\Diego\AI-Skills-Hub\` para `~\Diego\.archive\AI-Skills-Hub-pre-split-2026-05-16\` (não deletar — guarda como referência).

**Critério para sair da fase:** todos os 10 critérios de sucesso da §11 atendidos.

## 9. Setup & install

### Setup por repo

**`ai-skills-hub/setup.ps1`:**
- Garante que os **diretórios pai** existem: `~\.claude\skills\`, `~\.codex\skills\`, `~\.agents\skills\`, `~\.qwen\skills\`, `~\.antigravity\skills\`, `~\.gemini\antigravity\skills\`, `~\.gemini\extensions\`. **Não cria junctions** — junctions por-skill são criadas sob demanda quando o usuário roda `ai-skills enable <skill>` ou `ai-skills reconcile`.
- Registra shim `~\.local\bin\ai-skills.cmd`.
- Instala dependência Spectre.Console (ver §9.1).
- **NÃO toca em perfis, junctions de auth, env vars de perfil, ou Task Scheduler.**

**`octane/setup.ps1`:**
- Cria/valida junction `~\.claude-profiles\active` (apontando para `claude-a` se for primeira instalação).
- Cria/valida junction `~\.codex-profiles\active` (apontando para `~\.codex` — junction fixa, nunca muda de destino).
- Define env vars `CLAUDE_CONFIG_DIR`, `CODEX_HOME` (User scope) se não existirem.
- Registra Task Scheduler `ClaudeAutoRotate`, `CodexAutoRotate` (auto-rotate **desligado** por default via `Disable-ScheduledTask`).
- Registra shim `~\.local\bin\octane.cmd`.
- Instala dependência Spectre.Console (ver §9.1).
- **Invariante:** se `~\.claude-profiles\active` já existe e aponta para `claude-b`, **continua apontando para `claude-b`**. Setup nunca reseta para defaults.
- **NÃO toca em junctions de skills.**

### Orquestrador (máquina nova)

**`ai-skills-hub/setup-all.ps1`:**
- Aceita parâmetro `-OctanePath` (default: `~\Diego\octane`).
- Chama `octane/setup.ps1` primeiro (perfis + env vars vêm antes).
- Chama o próprio `setup.ps1` depois (skills).
- Detecta se octane existe; se não, instrui o usuário a clonar o repo octane primeiro.

### 9.1 Dependência Spectre.Console

Spectre.Console é um pacote .NET (~10MB). Estratégia:

- Setup de cada repo roda `dotnet tool install --global Spectre.Console.Cli` **se** o usuário tem .NET 8 SDK.
- Alternativa: cada repo carrega Spectre.Console.dll em `lib/spectre/` via `Install-Package Spectre.Console -Scope CurrentUser` na primeira execução. Sem dependência global.
- TUI carrega DLL via `Add-Type -Path` no início do script.
- Se Spectre não está disponível, `octane-tui.ps1` cai em fallback PowerShell puro (menu básico via `[Console]::ReadKey()`) com aviso.

### 9.2 Detecção de engine pelo prefixo do nome do perfil

Regra implementada no parser de comandos do `octane`:

| Prefixo do nome | Engine |
|-----------------|--------|
| `claude-*` | Claude |
| `codex-*` | Codex |
| `gemini-*` | Gemini |
| `qwen-*` | Qwen (futuro) |

Se o nome não bate em nenhum prefixo, o comando exige `--engine X` explícito.

## 10. Riscos e salvaguardas

### Camada 1 — Snapshot em 2 momentos

- **Fase 0:** `robocopy /MIR` de `~\.claude-profiles\`, `~\.codex-profiles\`, `~\.codex\` → `~\.profile-backups\2026-05-16-<hhmm>-fase0\`.
- **Fase 3.5:** segundo snapshot, imediatamente antes do cutover Fase 4.

Reversível com `robocopy /MIR` inverso a qualquer momento.

### Camada 2 — Invariante de propriedade exclusiva

- Setup do octane **verifica antes de modificar**. Se já existe, mantém.
- Hub nunca escreve em recurso de perfil.

### Camada 3 — Cutover atômico

- Tasks novas com sufixo `-v2` durante coexistência (Fase 4, 15 min).
- Tasks antigas desabilitadas (não removidas) durante validação.
- Auto-rotate **off por default** no octane novo.

### Atomic writes

- `Set-FileAtomic` e `Set-JsonFileAtomic` migrados igual para `Common.psm1` dos dois repos.
- Qualquer escrita em `auth.json`, `.credentials.json`, markers, configs → sempre tmp-write + rename.

### Critério de abort

Se qualquer fase falhar:

1. Os perfis em `~\.claude-profiles\` etc. estão intactos (Fases 1–3 não tocam nada fora do projeto; Fases 4–5 só tocam Task Scheduler e shims, ambos reversíveis).
2. `robocopy` inverso do snapshot mais recente restaura ao estado pré-fase, se necessário.
3. Reabilitar Task Scheduler antigo (que só foi desativado, não removido, até a sub-etapa final da Fase 4).

### Riscos cobertos

| Risco | Mitigação |
|-------|-----------|
| Perda/corrupção de credenciais | Snapshot duplo + atomic writes preservados |
| Task Scheduler antigo+novo rodando juntos | Sufixo `-v2` + cutover sequencial em Fase 4 |
| Junction `active` pós-cutover errada | `cutover-pre-*.txt` comparado; setup nunca reseta para defaults |
| `CLAUDE_CONFIG_DIR` apontando para caminho velho | Não muda — env var aponta para `~\.claude-profiles\active`, junction aponta para perfil; só o destino da junction muda em swap |
| Testes mestiços (RemoveProfilesAndCodexSync) | Split em `ProfileCrud.Tests.ps1` (octane) + `CodexSkillSync.Tests.ps1` (hub) |
| Conversa Claude Code ativa durante cutover | Auto-rotate off por default; switch manual confirma com modal |
| `tmp-*/` dirs no projeto atual | `.gitignore` exclui; não vão para repos novos |
| `backups/`, `backups-desktop-legacy/`, `exports/` | Ficam no archive; `.gitignore` exclui |
| Cross-talk monolito antigo × octane novo | Monolito antigo desligado antes de octane novo subir (Fases 4–5 fazem isso) |

## 11. Critérios de sucesso

1. `Invoke-Pester ~\Diego\ai-skills-hub\tests\` → 100% pass.
2. `Invoke-Pester ~\Diego\octane\tests\` → 100% pass.
3. `octane status` (sem painel rodando) lista perfis e uso corretamente.
4. `ai-skills list` (sem painel rodando) lista skills corretamente.
5. `octane-tui.ps1` abre TUI Spectre com gauges visíveis e responsivos a teclado.
6. Trocar de perfil em conversa Claude Code ativa funciona: junction swap detectado na próxima call de API.
7. Task Scheduler `ClaudeAutoRotate` executa com sucesso pelo menos uma vez (manual `-Force`).
8. Ambos web painéis (8765, 8766) carregam, mostram dados corretos.
9. Repo `octane` tem README próprio + LICENSE + setup.ps1 funcional do zero numa máquina limpa.
10. Repo `ai-skills-hub` tem README atualizado removendo todas as referências a Auth.
11. `octane doctor` e `ai-skills doctor` passam todas as checagens.
12. Snapshot Fase 3.5 idêntico ao Fase 0 (perfis intocados durante Fases 1–3).
13. Junction `~\.claude-profiles\active` aponta para o **mesmo perfil** antes e depois do cutover.

## 12. Pós-split (próximas iterações, fora do escopo desta migração)

- **Issue #1 do `octane`:** rate limits Codex cruzando entre perfis. Reproduzir, identificar (provavelmente `Get-CodexRateLimits` ou em `Get-CodexProfiles`), escrever teste Pester de regressão, fixar.
- Suporte oficial a Qwen no octane.
- Migração de Web UI para framework moderno (continua HTML/JS vanilla por enquanto).
- Distribuição via package manager (winget, scoop).
- Cross-platform (continua Windows-first).

## 13. Glossário

- **engine:** uma CLI de assistente AI (Claude, Codex, Gemini, Qwen).
- **perfil:** uma conta/credencial para uma engine. Cada engine pode ter vários perfis (ex: `claude-a`, `claude-b`).
- **swap:** trocar o perfil ativo de uma engine. No Claude/Gemini, faz via junction NTFS. No Codex, faz substituindo `auth.json`.
- **pit stop / rotate:** auto-rotate aciona swap quando uso atinge 95% do limite (5h ou 7d).
- **junction:** symlink NTFS (Windows). Usado para "hot-swap" sem reiniciar o processo da CLI.
- **marker:** arquivo pequeno em `~\.claude-active-dir` (ou `.codex-active-profile`) com o nome do perfil ativo. Lido pelo profile PowerShell.
- **doctor:** comando de diagnóstico — verifica junctions, env vars, tasks scheduler, markers.

---

**Próximo passo:** writing-plans cria o plano de implementação tarefa-a-tarefa com critérios de validação Pester por etapa.
