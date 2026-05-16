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
git clone https://github.com/diegocamara89/ai-skills-hub.git C:\Users\<you>\Diego\skill-hub
cd C:\Users\<you>\Diego\skill-hub
.\setup.ps1
.\manage-skills.ps1 status
```

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

## Tests

```powershell
Invoke-Pester -Path tests -Output Detailed
```

## Dependências

- Windows 10/11
- PowerShell 7+
- Pester 5+ (testes)
- git, gh CLI (importador)

## Issues conhecidas (pós-split)

- **#1:** Refatorar `manage-skills.ps1` em módulos `.psm1` (extração incremental por função, com testes Pester em PRs separados).
- **#2:** Distribuição via package manager (winget/scoop).
- **#3:** Cross-platform support (atual: Windows-first).
