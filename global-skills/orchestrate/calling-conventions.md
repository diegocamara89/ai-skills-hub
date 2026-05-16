# Convencoes de Chamada - Como Chamar Cada IA via CLI

> Este documento define os comandos EXATOS para chamar cada IA.
> Testado e validado no ambiente do usuario (Windows + Git Bash/MSYS2).
> **Atualizado em 2026-04-05** com licoes aprendidas em producao (pipeline URGA).

---

## REGRA DE OURO: ENTREGA DO PROMPT

> **APRENDIDO EM PRODUCAO**: O metodo `-p "texto"` CORROMPE prompts no Windows.
> O `cmd.exe` interpreta `{`, `}`, `|` e `%` como operadores de shell,
> destruindo silenciosamente o conteudo enviado a IA.

| Metodo | Quando usar | Risco |
|--------|-------------|-------|
| **stdin pipe** (RECOMENDADO) | Prompts com conteudo variavel (curriculos, codigo, JSON, dados) | Nenhum |
| `-p "texto"` | Prompts curtos (< 500 chars) sem caracteres especiais | ALTO se tiver `{}|\%` |
| `@arquivo` (Gemini) | Prompts grandes pre-montados | Nenhum (requer arquivo temp) |

**Limite do cmd.exe**: 8191 caracteres maximo em argumento de linha de comando.

### stdin pipe — Padrao SEGURO para todas as IAs
```bash
# Codex: flag '-' le de stdin
echo "seu prompt" | unset OPENAI_BASE_URL && unset OPENAI_API_KEY && codex exec --skip-git-repo-check -

# Qwen: le de stdin nativamente
echo "seu prompt" | qwen

# Gemini: usar @arquivo (nao suporta stdin direto)
cat > /tmp/prompt.txt << 'EOF'
seu prompt aqui
EOF
gemini -m gemini-3-flash-preview -p "@/tmp/prompt.txt"
```

### Detector de prompt corrompido
Se a IA responder com frases como estas, o prompt chegou corrompido:
- "Preciso do curriculo", "Pode colar o conteudo", "Nao recebi"
- "Please provide", "I need the", "I don't have"

**Solucao**: Trocar de `-p` para stdin pipe e reenviar.

---

## 1. GEMINI CLI

### Chamada direta
```bash
# Prompt simples (APENAS para texto curto sem caracteres especiais)
gemini -m gemini-3-pro-preview -p "seu prompt aqui"

# Prompt de arquivo (RECOMENDADO para conteudo variavel)
gemini -m gemini-3-flash-preview -p "@caminho/do/arquivo.txt"

# Com output JSON
gemini -m gemini-3-pro-preview --output-format json -p "@/tmp/prompt.txt"
```

### Timeout recomendado
- Flash: 120s (2min)
- Pro: 300s (5min)
- Analises longas: 600s (10min) via Bash tool com timeout

### Parsing de saida
- Saida em texto puro por padrao
- Com `--output-format json`: JSON direto
- Para extrair JSON de texto misto: usar parser balanceado (ver secao abaixo)

### ATENCAO: Instabilidade em lote
- Rate limit agressivo com 2+ chamadas simultaneas (HTTP 429)
- `rc=130` ("Operation cancelled") intermitente sem causa aparente
- Stderr poluido com `[IDEClient] Failed to connect to IDE companion extension` (filtrar)
- **Para lotes >20 itens**: preferir Codex ou Qwen como worker

---

## 2. CODEX CLI

### CRITICO: Limpar variaveis OpenRouter antes de chamar
```bash
# OBRIGATORIO quando chamado pelo Claude (que usa OpenRouter)
unset OPENAI_BASE_URL && unset OPENAI_API_KEY && codex exec --skip-git-repo-check "prompt"
```

### Chamada via stdin pipe (RECOMENDADA)
```bash
# Flag '-' le o prompt de stdin — seguro para qualquer conteudo
echo "prompt com {chaves} e |pipes|" | \
  unset OPENAI_BASE_URL && unset OPENAI_API_KEY && \
  codex exec --skip-git-repo-check -
```

### Chamada direta (apenas prompts curtos sem caracteres especiais)
```bash
codex exec --skip-git-repo-check "prompt simples"

# Com sandbox de escrita
codex exec --skip-git-repo-check --sandbox workspace-write "prompt"

# Com modelo especifico
codex exec --skip-git-repo-check -m o3 "prompt"
```

### Timeout recomendado
- Padrao: 120s
- Tarefas complexas: 300s
- Maximo: 1800s (30min)

### Parsing de saida
- Saida em texto puro
- Codex tende a ser direto e conciso
- Para JSON: pedir explicitamente no prompt

### Ponto forte: Estabilidade em lote
- Testado com 63 chamadas consecutivas sem falha (pipeline URGA)
- stdin pipe funciona de forma confiavel com qualquer conteudo
- 1 chamada combinada pode substituir 2 chamadas Gemini (analise + validacao)

---

## 3. QWEN CLI

### Chamada via stdin pipe (RECOMENDADA)
```bash
# stdin pipe — seguro para qualquer conteudo
echo "prompt com {chaves} e |pipes|" | qwen
```

### Chamada direta (apenas prompts curtos)
```bash
# Prompt simples
qwen -p "prompt"

# Modo autonomo (executa codigo)
qwen -p "prompt" --yolo
```

### Via arquivo temporario (Windows - para prompts grandes)
```bash
# Escrever prompt em arquivo temp, depois pipe
cat > /tmp/qwen_prompt.txt << 'PROMPT_EOF'
prompt grande aqui
PROMPT_EOF
cat /tmp/qwen_prompt.txt | qwen && rm /tmp/qwen_prompt.txt
```

### Timeout recomendado
- Padrao: 60s
- Tarefas maiores: 120s

### Parsing de saida
- Saida em texto puro com formatacao Markdown
- Qwen e mais verboso - pode precisar de limpeza
- Para JSON: pedir "Responda APENAS JSON, sem texto adicional"

### Limites
- 2.000 requisicoes/dia via OpenRouter; sem limite via Ollama local

---

## 4. CLAUDE CODE

### Chamada via stdin pipe (RECOMENDADA — testada em producao 2026-04-05)
```bash
# Stdin pipe — seguro para qualquer conteudo, sem corrupcao de {|}%
echo "prompt com {chaves} e |pipes|" | claude --print

# Para prompts grandes: arquivo temporario + pipe
cat > /tmp/claude_prompt.txt << 'EOF'
seu prompt aqui
EOF
cat /tmp/claude_prompt.txt | claude --print && rm -f /tmp/claude_prompt.txt
```

### Via PowerShell (alternativa equivalente)
```powershell
$content = Get-Content -Path "/tmp/claude_prompt.txt" -Raw
$result = $content | claude --print
```

### Timeout recomendado
- Tarefas simples: 120s
- Tarefas complexas: 300s

### NOTA: o que NAO funciona no Windows
```bash
claude --print < arquivo.txt  # FALHA — PowerShell reserva o operador '<'
claude -p "prompt longo"      # RISCO — cmd.exe corrompe {|}%
```

### Quando Claude e o ORQUESTRADOR (dentro do Claude Code)
Nao use subprocess. Use o Agent tool nativo para chamar Codex,
e o Bash tool com stdin pipe para chamar Gemini e Qwen.

---

## WINDOWS: KILL DE ARVORE DE PROCESSO

> **APRENDIDO EM PRODUCAO**: `subprocess.run(timeout=N)` NAO mata processos filhos no Windows.
> `cmd.exe` cria arvore de processos — timeout so mata o pai, filhos continuam. Resultado: 120s pode levar 279s+.

**Solucao**: Use `Popen` com `creationflags=CREATE_NEW_PROCESS_GROUP`. Em `TimeoutExpired`, chame `taskkill /F /T /PID <pid>` (nao `proc.kill()`), depois `proc.wait(timeout=5)`.

A implementacao completa esta em `scripts/run_ai_cli.py`.

---

## FILTRO DE STDERR

O Gemini emite ruido inofensivo no stderr: `[IDEClient] Failed to connect to IDE companion extension`. **NAO trate stderr como indicador de falha.** Ignore linhas contendo: `IDEClient`, `cached credentials`, `companion extension`, `mcp:`.

---

## EXTRACAO DE JSON

> **APRENDIDO EM PRODUCAO**: `grep -oP '\{.*\}'` e GULOSO — casa do primeiro `{` ao ultimo `}` do texto inteiro. Use parser balanceado com 3 niveis de fallback: (1) texto puro, (2) bloco markdown ```json```, (3) varredura caracter a caracter com depth counter.

Implementacao em `scripts/run_ai_cli.py`. Para retry com backoff, use `for i in 1 2 3; do ... && break; sleep $((5 * 3 ** ($i-1))); done`.
