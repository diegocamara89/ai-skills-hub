# Convencoes de chamada no PowerShell

## Regra principal no Windows

Neste ambiente, os shims `.ps1` de `codex`, `gemini` e `qwen` podem falhar por politica de execucao.

Prefira:

- `codex.cmd`
- `gemini.cmd`
- `qwen.cmd`
- `claude.exe` real

Quando quiser padronizar descoberta de executavel, timeout e captura, use:

```powershell
python .\all-skills\orchestrate\scripts\run_ai_cli.py ...
```

ou:

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py ...
```

## Claude por perfil

```powershell
$env:CLAUDE_CONFIG_DIR = "$env:USERPROFILE\.claude-profiles\claude-a"
& "C:\caminho\para\claude.exe" -p "planeje a tarefa"
```

Se quiser deixar o wrapper cuidar do failover:

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py call-claude --prompt "planeje a tarefa"
```

## Codex

```powershell
cmd /c codex.cmd exec --skip-git-repo-check "implemente a tarefa"
```

Via wrapper:

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py call-codex --prompt "implemente a tarefa" --working-dir C:\repo
```

## Gemini

```powershell
cmd /c gemini.cmd -m gemini-3-flash-preview -p "analise a tarefa"
```

## Qwen

```powershell
cmd /c qwen.cmd -p "analise a tarefa"
cmd /c qwen.cmd -p "analise a tarefa" --yolo
```

## Extensoes Gemini

O Gemini CLI suporta extensoes locais e GitHub.

Link local:

```powershell
cmd /c gemini.cmd extensions link C:\caminho\da\extensao --consent
```

Instalacao por origem:

```powershell
cmd /c gemini.cmd extensions install https://github.com\owner\repo --consent
```

## Dica para prompts grandes

- prefira arquivo UTF-8 quando a CLI suportar
- evite colar contexto sensivel direto no argumento do shell
- se precisar reduzir contexto para subagentes nativos, combine esta skill com `persona-bridge`
