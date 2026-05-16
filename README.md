# AI Skills Hub

Hub central de skills para Claude/Codex/Qwen/Antigravity/Gemini, com sincronização via junctions NTFS.

> **Auth multi-CLI:** ver repo separado [`diegocamara89/octane`](https://github.com/diegocamara89/octane) para gestão de perfis, OAuth e auto-rotate.

## Status

Este repositório resultou do split do `AI-Skills-Hub` monolítico (2026-05-16). O catálogo de skills ficou aqui; a parte de auth multi-CLI foi extraída para o repo `octane`. Spec do split em [`docs/superpowers/specs/2026-05-16-split-skills-hub-octane-design.md`](docs/superpowers/specs/2026-05-16-split-skills-hub-octane-design.md) (arquivado em `archive/monolith-v1`).

> **Nota de path local:** Durante a migração, o folder local tem nome `skill-hub` para evitar colisão case-insensitive com o antigo `AI-Skills-Hub`. Após a Fase 5 do split (archive do antigo), o folder será renomeado para `ai-skills-hub` casando com o nome do repo GitHub.

## Estrutura

```
skill-hub/
├── all-skills/              # 45 skills (source of truth)
├── global-skills/           # junctions ativas (apontam para all-skills)
├── lib/
│   ├── frontmatter-validator.ps1
│   ├── skill-lockfile.ps1
│   └── upstream-importer.ps1
├── ui/index.html            # web UI (porta 8765)
├── state/
│   ├── superpowers/         # estado de sync nativo
│   └── managed-targets.json # estado de gestão de skills
├── tests/                   # Pester (138 tests)
├── manage-skills.ps1        # CLI principal (monolito legado — refactor futuro)
├── ai-skills.ps1            # CLI wrapper (talks to HTTP server)
├── skill-manager.bat        # launcher da UI
└── setup.ps1                # setup só-Hub
```

## Quickstart

```powershell
# Em máquina nova: clone para o nome canônico
git clone https://github.com/diegocamara89/ai-skills-hub.git C:\Users\<you>\Diego\ai-skills-hub
cd C:\Users\<you>\Diego\ai-skills-hub
.\setup.ps1
.\manage-skills.ps1 status
```

> Na máquina do autor, o folder local se chama `skill-hub` (não `ai-skills-hub`) como mitigação temporária da colisão case-insensitive com o folder legado `AI-Skills-Hub` durante a migração. Após arquivamento do legado, o folder pode ser renomeado para `ai-skills-hub` para casar com o repo GitHub. **Em máquinas novas, use o nome canônico (`ai-skills-hub`) direto** — não há colisão.

## Comandos principais

```powershell
.\manage-skills.ps1 status                                # estado geral
.\manage-skills.ps1 enable-global -Skills napkin,doc      # ativar skills globalmente
.\manage-skills.ps1 disable-global -Skills napkin         # desativar
.\manage-skills.ps1 reconcile                             # recria junctions a partir do estado
.\manage-skills.ps1 sync-native-superpowers               # sincroniza plugin nativo superpowers
.\manage-skills.ps1 import-existing                       # importa skills de outras fontes
.\manage-skills.ps1 sync-project -ProjectPath C:\repo     # sincroniza skills de projeto
```

## Web UI

```powershell
.\skill-manager.bat
# Abre http://localhost:8765
```

UI permite marcar em quais agentes (Claude, Codex, Qwen, Antigravity, Gemini) cada skill deve ficar instalada.

## Diretórios alvo

- Claude: `%USERPROFILE%\.claude\skills`
- Codex legacy: `%USERPROFILE%\.codex\skills`
- Codex user: `%USERPROFILE%\.agents\skills`
- Qwen: `%USERPROFILE%\.qwen\skills`
- Antigravity: `%USERPROFILE%\.antigravity\skills`
- Gemini: `%USERPROFILE%\.gemini\antigravity\skills` (legado) e `%USERPROFILE%\.gemini\extensions` (nativo)

Setup do Hub apenas garante que esses diretórios pai existem. Junctions individuais por skill são criadas sob demanda via `enable-global` ou `reconcile`.

## Importação GitHub

O importador aceita apenas repositórios com `SKILL.md` na raiz.

Rejeita:
- pacotes multi-skill
- extensões nativas
- repositórios sem `SKILL.md` raiz

Para pacotes multi-skill como `superpowers`, use `sync-native-superpowers`.

## Shims (CLI global)

`setup.ps1` cria shim `~/.local/bin/ai-skills.cmd` que aponta para o `ai-skills.ps1` do Hub. Tendo `~/.local/bin/` no PATH do usuário, você pode rodar `ai-skills <cmd>` de qualquer lugar — mas ele é um wrapper HTTP (precisa do painel rodando em :8765). Para uso standalone (sem painel), invoque `manage-skills.ps1` diretamente.

## Tests

```powershell
Invoke-Pester -Path tests -Output Detailed
```

Baseline atual: 26 tests pass (FrontmatterValidator + SkillLockfile + UpstreamImporter).

## Dependências

- Windows 10/11
- PowerShell 7+
- Pester 5+ (testes)
- git, gh CLI (importador)

## Issues conhecidas (pós-split)

- **#1:** Refatorar `manage-skills.ps1` em módulos `.psm1` (extração incremental por função, com testes Pester em PRs separados). O plano original previa big-bang; pivot escolheu cópia integral + extração incremental pós-split — ver `docs/superpowers/plans/2026-05-16-split-skills-hub-octane-implementation.md`.
- **#2:** CLI standalone — `ai-skills.ps1` é wrapper HTTP. Refatorar para chamar funções core diretamente sem precisar de painel rodando.
- **#3:** Distribuição via package manager (winget/scoop).
- **#4:** Cross-platform support (atual: Windows-first).

## Backup da migração 2026-05-16

- Snapshot completo dos perfis em `~\.profile-backups\2026-05-16-1237-fase0\` e `~\.profile-backups\2026-05-16-1322-fase35\` (~880MB)
- Código pré-split commit `00ea5aa` preservado na branch `archive/monolith-v1` deste repo
