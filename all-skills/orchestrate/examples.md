# Exemplos Praticos - Cenarios Reais

> Baseados nos scripts reais do usuario.
> Estes sao EXEMPLOS para inspirar, nao templates rigidos.

---

## EXEMPLO 1: Auditoria de Anonimizacao (LGPD)

**Cenario**: Verificar se documentos foram anonimizados corretamente.

**Equipe sugerida**:
```
Auditor 1: Gemini Flash (varredura rapida)
Auditor 2: Qwen (segunda opiniao)
Consolidador: Claude (relatorio final)
```

**Execucao**:
```bash
# Montar prompt em arquivo temporario (SEGURO - evita escaping e limite de CLI)
cat > /tmp/audit_prompt.txt << 'PROMPT_EOF'
Voce e um auditor LGPD. Analise o documento abaixo e encontre QUALQUER dado pessoal real nao anonimizado.
Responda APENAS JSON: {"status":"APROVADO|REPROVADO","dados_encontrados":[{"dado":"...","tipo":"..."}],"total_vazamentos":0}
PROMPT_EOF
cat documento.txt >> /tmp/audit_prompt.txt

# Auditor 1 - Gemini (paralelo)
gemini -m gemini-3-flash-preview -p "@/tmp/audit_prompt.txt" > /tmp/resultado_gemini.json &

# Auditor 2 - Qwen (paralelo)
qwen -p "@/tmp/audit_prompt.txt" > /tmp/resultado_qwen.json &
wait

# Limpar prompts temporarios
rm -f /tmp/audit_prompt.txt

# Claude consolida ambos os resultados
```

**Fluxo de discussao com usuario**:
```
Claude: Para auditar a anonimizacao, sugiro:
  - Gemini Flash como auditor principal (rapido, especializado em varredura)
  - Qwen como segundo auditor (perspectiva alternativa)
  - Eu consolido os resultados e gero relatorio
  Especialidades complementares garantem auditoria rigorosa.
  Posso executar?
```

---

## EXEMPLO 2: Avaliacao Curricular em Lote (BASICO)

**Cenario**: Avaliar ate 20 curriculos com criterios especificos.

> **Para lotes >20 curriculos**, usar Padrao 9 / Exemplo 7 (pipeline resiliente com Codex).
> Gemini e instavel em lotes grandes (rate limit 429, rc=130).

**Equipe sugerida**:
```
Worker: Codex ou Qwen (processa todos via stdin pipe)
QA: Gemini Pro (valida amostra de 10%, pontual)
Relatorio: Claude (ranking final, dashboard)
```

**Execucao**:
```bash
# Worker processa cada curriculo via stdin pipe (SEGURO)
for arquivo in curriculos/*.txt; do
    prompt="Avalie este curriculo (0-100) para a vaga X. JSON: {score, recomendacao, justificativa}."
    prompt="$prompt\n\nCurriculo:\n$(cat $arquivo)"
    echo "$prompt" | qwen >> resultados.jsonl
    sleep 1  # rate limit
done

# QA valida amostra (Gemini pontual, OK)
amostra=$(shuf -n 5 resultados.jsonl)
cat > /tmp/qa_prompt.txt << EOF
Valide estas avaliacoes. Estao coerentes?
$amostra
EOF
gemini -m gemini-3-pro-preview -p "@/tmp/qa_prompt.txt"
```

---

## EXEMPLO 3: Analise Arquitetural de Codigo

**Cenario**: Analisar arquivo complexo (4000+ linhas) para refatoracao.

**Equipe sugerida**:
```
Arquiteto: Gemini Pro (anti-patterns, SOLID)
Debugger: Codex (bugs especificos)
Professor: Qwen (explicacao educativa)
CTO: Claude (roadmap de refatoracao, ROI)
```

**Execucao**: PARALELO (os 3 primeiros), depois Claude consolida.
```bash
# Preparar prompt via arquivo (seguro para arquivos grandes)
cat > /tmp/prompt_arq.txt << 'EOF'
Identifique anti-patterns e violacoes SOLID no codigo abaixo. Responda em JSON.
EOF
cat codigo.js >> /tmp/prompt_arq.txt

# Paralelo - cada IA recebe via @arquivo
gemini -m gemini-3-pro-preview -p "@/tmp/prompt_arq.txt" > /tmp/arquitetura.json &
unset OPENAI_BASE_URL && unset OPENAI_API_KEY && codex exec --skip-git-repo-check "Encontre bugs no arquivo codigo.js neste diretorio" > /tmp/bugs.txt &
qwen -p "Explique como melhorar o codigo em codigo.js com exemplos praticos" > /tmp/review.txt &
wait

# Limpeza de temporarios
rm -f /tmp/prompt_arq.txt

# Claude consolida os 3 resultados
```

---

## EXEMPLO 4: Normalizacao de Dados com IA

**Cenario**: Mapear nomes livres para siglas oficiais.

**Equipe sugerida**:
```
Worker: Qwen (normalizacao item a item, rapido)
Validador: Gemini Flash (confirma mapeamentos duvidosos)
```

**Execucao**: SEQUENCIAL
```bash
# Qwen normaliza
qwen -p "Lista oficial: [DPCA, DRCC, DPI, ...]. Qual sigla para 'Delegacia de Protecao a Crianca'? Responda APENAS a sigla."

# Se Qwen retornar algo duvidoso, Gemini confirma
gemini -m gemini-3-flash-preview -p "A sigla oficial para 'Delegacia de Protecao a Crianca' e DPCA? Sim ou Nao."
```

---

## EXEMPLO 5: Investigacao de Bug Critico

**Cenario**: Bug em producao, precisa de diagnostico urgente.

**Equipe sugerida**:
```
Diagnostico: Codex (encontra o bug exato)
Contexto: Qwen (explica o impacto)
Plano: Claude (define correcao segura)
```

**Execucao**: SEQUENCIAL (cada etapa informa a proxima)
```bash
# 1. Codex identifica
unset OPENAI_BASE_URL && unset OPENAI_API_KEY && codex exec --skip-git-repo-check "Por que a funcao X na linha 1282 causa stale data?"

# 2. Qwen contextualiza
qwen -p "Explique o impacto de stale data na funcao X e quais modulos sao afetados"

# 3. Claude planeja correcao
# (Claude ja esta aqui, consolida e planeja)
```

---

## EXEMPLO 6: Brainstorm Multi-Perspectiva

**Cenario**: Decidir abordagem para nova feature.

**Equipe sugerida**:
```
Todos recebem o MESMO prompt, cada um da sua perspectiva:
  - Claude: Visao de negocio e ROI
  - Gemini Pro: Viabilidade tecnica e arquitetura
  - Codex: Complexidade de implementacao e alternativas
```

**Execucao**: PARALELO
```bash
prompt="Como implementar autenticacao SSO no sistema X? Considere complexidade, manutencao e seguranca."

gemini -m gemini-3-pro-preview -p "$prompt" > /tmp/gemini.txt &
qwen -p "$prompt" > /tmp/qwen.txt &
wait

# Claude analisa as 3 perspectivas (incluindo a propria)
```

---

## EXEMPLO 7: Avaliacao Curricular em Lote — Caso Real URGA (Padrao 9)

> **Caso real validado em producao** (26/02/2026).
> 63 curriculos avaliados com 100% de sucesso em 397 segundos.
> Referencia de implementacao: `avaliar_urga_orquestrado.py` (v3).

**Cenario**: Avaliar 63 curriculos de candidatos do concurso PCRN para a URGA
(Unidade de Recuperacao e Gestao de Ativos). Cada curriculo precisa ser analisado
contra competencias especificas (contabilidade, PLD, COAF/SISBAJUD, etc.) com
evidencias a favor/contra e recomendacao final.

**Evolucao do pipeline (licoes aprendidas)**:

| Versao | Arquitetura | Resultado |
|--------|-------------|-----------|
| v1 | Gemini Flash (analise) + Gemini Pro (validacao), prompt via `-p` | **FALHOU** — prompt corrompido, timeout ineficaz, rate limit 429 |
| v2 | Gemini Flash + Pro com stdin pipe e fixes | **INSTAVEL** — Gemini continuou com rc=130 e timeouts |
| v3 | **Codex unico** via stdin pipe, 1 chamada/candidato | **SUCESSO** — 63/63 em 397s |

**Equipe final (v3)**:
```
Preflight: Verificar codex e qwen no PATH
  |
  v
Worker Pool (2 threads):
  +-- Worker: Codex (stdin pipe, prompt combinado analise+decisao)
  +-- Fallback: Qwen (automatico apos 3 falhas do Codex)
  |
  v
Para cada candidato:
  1. Ler curriculo.txt + analise_perfil_ia.json
  2. Montar prompt com PERFIL_URGA + dados do candidato
  3. Enviar via stdin pipe: codex exec --skip-git-repo-check -
  4. Extrair JSON com parser balanceado (3 niveis)
  5. Salvar checkpoint atomico (tmp → fsync → rename)
  |
  v
Consolidador: Claude (gera relatorio MD + HTML de apresentacao)
```

**Execucao (subprocess Python)**:
```python
import subprocess, os

env = os.environ.copy()
env.pop('OPENAI_BASE_URL', None)
env.pop('OPENAI_API_KEY', None)

proc = subprocess.Popen(
    ['codex', 'exec', '--skip-git-repo-check', '-'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, encoding='utf-8', env=env,
    creationflags=getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0)
)
try:
    stdout, stderr = proc.communicate(input=prompt_text, timeout=300)
except subprocess.TimeoutExpired:
    # OBRIGATORIO: matar arvore inteira no Windows
    subprocess.run(['taskkill', '/F', '/T', '/PID', str(proc.pid)],
                   capture_output=True, timeout=10)
    proc.wait(timeout=5)
    raise
```

**Resultado**: 63 candidatos | 397s total | 1 Sim, 61 Parcial, 1 Nao | 100% sucesso

**Bugs encontrados e resolvidos na jornada**:
1. Prompt corrompido via `-p` (chars `{}|%` interpretados pelo cmd.exe)
2. Timeout ineficaz no Windows (processos filhos nao morrem)
3. Regex gulosa `\{[\s\S]*\}` na extracao de JSON
4. Checkpoint nao-atomico (corrupcao em interrupcao)
5. `except:` bare engolindo Ctrl+C
6. Stderr do Gemini (IDEClient) tratado como erro
7. Rate limit 429 do Gemini com 2+ workers simultaneos

---

## ANTI-PADROES

> Anti-padroes detalhados e proibicoes tecnicas de shell estao em SKILL.md.
> Aqui apenas lembretes rapidos contextualizados nos exemplos acima.

- Nao escale: 1 IA basta para perguntas simples
- Nao envie dados brutos: use arquivo temp, nunca `$(cat sensivel.txt)` inline
- Nao ignore erros: retry com backoff ou IA alternativa
- Use especialidade certa: Qwen/Gemini Flash para triagem rapida, Codex/Claude para analise profunda
- **Nao use `-p` para prompts com conteudo variavel**: chars `{}|%` corrompem no Windows → use stdin pipe
- **Nao confie em `proc.kill()` no Windows**: use `taskkill /F /T /PID` para matar arvore inteira
- **Nao use regex gulosa para JSON**: `\{[\s\S]*\}` engole tudo → use parser balanceado
- **Nao use `except:` sem tipo**: engole KeyboardInterrupt → use excecoes especificas
- **Nao assuma que Gemini e estavel em lote**: rate limit 429 e rc=130 aparecem apos ~20 chamadas
- **Nao trate stderr como erro**: filtrar ruido conhecido (IDEClient, cached credentials)
- **Nao use `@arquivo` para Gemini no Windows via subprocess**: timeout expiram (60-120s), use PowerShell + pipe nativo (`Get-Content | gemini`) com timeout 300s+
