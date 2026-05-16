# Orquestrador Windows

## Visao geral

O v1 desta skill assume este fluxo:

1. `Claude` planeja
2. `Codex` executa
3. `Claude` valida so quando o risco justificar

O wrapper `claude_codex_orchestrator.py` existe para estabilizar esse fluxo no Windows.

## Por que o wrapper existe

- manter duas ou mais contas Claude autenticadas no mesmo usuario do Windows
- trocar de perfil automaticamente quando houver erro claro de cota
- chamar `codex.cmd`, `gemini.cmd` e `qwen.cmd` sem depender do shim `.ps1`
- devolver para o Claude um handoff enxuto e previsivel

## Estrutura padrao fora do repositorio

```text
%USERPROFILE%\.claude-orchestrator\
|-- config.json
|-- state.json
|-- statusline-tools\
|   |-- claude_statusline_collector.ps1
|   `-- claude_statusline_collector.py
`-- usage\
    `-- profiles\

%USERPROFILE%\.claude-profiles\
|-- claude-a\
|-- claude-b\
|-- claude-c\
`-- ... ate claude-j
```

## Bootstrap inicial

1. Gere ou ajuste o config:

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py print-template-config --output %USERPROFILE%\.claude-orchestrator\config.json
```

2. Prepare os perfis:

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py bootstrap-profiles --config %USERPROFILE%\.claude-orchestrator\config.json
```

3. Faça o primeiro login manual em cada perfil Claude:

```powershell
$env:CLAUDE_CONFIG_DIR = "$env:USERPROFILE\.claude-profiles\claude-a"
& "C:\caminho\para\claude.exe"

$env:CLAUDE_CONFIG_DIR = "$env:USERPROFILE\.claude-profiles\claude-b"
& "C:\caminho\para\claude.exe"
```

Depois disso, o wrapper passa a reaproveitar a autenticacao persistente de cada perfil.

Se voce quiser crescer a frota de perfis sem editar JSON manualmente:

```powershell
.\manage-skills.ps1 add-claude-profile
```

O limite operacional implementado nesta versao e `10` perfis.

## Comandos principais

### Planejamento ou chamada isolada do Claude

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py call-claude --prompt "planeje a tarefa X"
```

Para forcar um modelo especifico do Claude:

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py call-claude --model opus --prompt "planeje a tarefa X"
```

### Execucao isolada no Codex

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py call-codex --prompt "implemente X" --working-dir C:\repo
```

### Fluxo completo

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py route --task "implemente X" --working-dir C:\repo
```

Para testar um fluxo `Opus -> Sonnet -> Claude`, use:

```powershell
python .\all-skills\orchestrate\scripts\claude_codex_orchestrator.py route `
  --task "implemente X" `
  --working-dir C:\repo `
  --planner-model opus `
  --executor-provider claude `
  --executor-model sonnet `
  --validation-model sonnet
```

## Failover reativo

O wrapper nao gira perfil Claude por antecedencia.

Ele so faz failover quando detectar no retorno do Claude algo como:

- `usage limit reached`
- `quota exceeded`
- `rate limit reached`

Esse comportamento segue a premissa do projeto: failover apenas quando houver erro claro de cota.

## Handoff do executor

O Codex deve ser resumido de volta ao Claude em:

- `status`
- `task_summary`
- `changed_files`
- `tests_run`
- `risks`
- `analyst_summary`
- `next_action`

Se o executor nao devolver JSON, o wrapper sintetiza esse handoff a partir da saida textual.

## Quando validar no Claude

Por padrao, a validacao final acontece apenas quando houver:

- risco alto
- alteracao multiarquivo
- testes ausentes
- pedido explicito do usuario
- falha do executor exigindo arbitragem

## Integracoes nativas

Para `superpowers`, use o hub para sincronizar instalacoes nativas e nunca importe a raiz GitHub como skill unica se ela vier como pack multi-skill ou extensao.

Comando previsto no hub:

```powershell
.\manage-skills.ps1 sync-native-superpowers -Install -Force
```

## Painel de autenticacao e uso

O hub agora exibe `http://localhost:8765/claude-auth`, com:

- login por perfil Claude com link OAuth copiavel
- criacao incremental de perfis
- status de autenticacao
- instalacao do coletor de uso por `statusLine`
- metricas oficiais do ultimo snapshot (`5h`, `7d`, reset e custo/sessao)
- agregados locais por `5h`, `dia`, `semana` e `modelo`

Para instalar a coleta via CLI:

```powershell
.\manage-skills.ps1 sync-claude-usage-collector -Force
```

O coletor usa `all-skills\orchestrate\scripts\claude_statusline_collector.ps1` para chamar o parser Python e gravar snapshots em:

```text
%USERPROFILE%\.claude-orchestrator\usage\
```

Os scripts efetivamente executados pelo Claude sao copiados para:

```text
%USERPROFILE%\.claude-orchestrator\statusline-tools\
```

Isso evita falhas causadas por caminhos com espacos no nome do repositorio.

## Launcher de dois cliques

Para abrir direto no painel correto:

```powershell
.\abrir-painel-claude-auth.bat
```

Esse launcher sobe o backend e abre `http://localhost:8765/claude-auth`.
