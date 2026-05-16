# Upstream / Importação

Origem dos materiais importados para esta skill:
- Pasta fonte (local): `agent-skills-master_extracted/agent-skills-master`
- Autor indicado no README upstream: Diego Câmara
- Licença: MIT (ver `references/LICENSE`)

Notas de importação para Codex:
- O upstream foi escrito para “skills” genéricas via CLI (Claude Code/Antigravity/Cursor/Codex).
- Aqui, a skill foi adaptada para:
  - frontmatter YAML mínimo (`name` + `description`);
  - suporte explícito a **multiagentes nativos do Codex** (sem CLI externa);
  - convenções de chamada em **PowerShell** (Windows).

