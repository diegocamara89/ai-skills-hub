# Napkin Runbook

## Curation Rules
- Re-prioritize on every read.
- Keep recurring, high-value notes only.
- Max 10 items per category.
- Each item includes date + "Do instead".

## Execution & Validation (Highest Priority)
1. **[2026-03-30] Python 3.14 venv may come up without pip in this workspace**
   Do instead: bootstrap installs with `python -m pip --python <venv-python> ...` instead of assuming `venv\Scripts\python.exe -m pip` works.
2. **[2026-04-03] Usuario quer respostas somente em pt-BR**
   Do instead: responder em portugues do Brasil em toda a conversa, inclusive handoffs, resumos e opcoes de execucao.

## Shell & Command Reliability
1. **[2026-04-03] Bundled `rg.exe` can fail with `Acesso negado` in this desktop environment**
   Do instead: fall back to PowerShell `Select-String` plus `Get-ChildItem`, or use `git grep` only inside actual nested repos.
2. **[2026-03-30] Direct `.ps1` execution is blocked by local execution policy**
   Do instead: invoke repo runners with `powershell -ExecutionPolicy Bypass -File <script.ps1>`.
3. **[2026-04-01] npm CLI shims for `codex`, `gemini`, and `qwen` fail when PowerShell resolves the `.ps1` wrapper first**
   Do instead: call the `.cmd` shim explicitly on Windows, or route through a wrapper that resolves `%APPDATA%\npm\<tool>.cmd`.
4. **[2026-04-01] Claude plugin commands can fail inside the sandbox with `uv_spawn 'reg'`**
   Do instead: validate Claude plugin installs with escalated execution or mocked checks, and keep local docs for the expected install path and marketplace entry.
