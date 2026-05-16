---
name: verification-loop
description: A comprehensive verification system for code quality assurance. Run after implementing features or every 15 minutes in long sessions. Checks build, types, lint, tests, security, and diff in 6 sequential phases.
origin: ECC
---

# Verification Loop

Sistema de QA sistemático em 6 fases sequenciais para garantir qualidade do código antes de commitar ou encerrar uma sessão.

## When to Activate

- Ao terminar uma feature ou bug fix
- A cada 15 minutos em sessões longas de desenvolvimento
- Antes de commitar código
- Após refatorações
- Ao receber erro de build ou teste

## The 6-Phase Verification Loop

### Phase 1: Build Verification
Confirma que o projeto compila sem erros.

```bash
# Node.js / Next.js
npm run build
# ou
pnpm build

# Python
python -m py_compile src/**/*.py
# ou
uv run python -m pytest --co -q  # apenas coleta, não executa
```

**Critério:** Build deve completar sem erros. Resolver antes de continuar.

---

### Phase 2: Type Check
Verificação estática de tipos.

```bash
# TypeScript
npx tsc --noEmit

# Python
npx pyright
# ou
mypy src/
```

**Critério:** Zero erros de tipo. Warnings podem ser revisados separadamente.

---

### Phase 3: Lint Check
Verificação de estilo e padrões de código.

```bash
# JavaScript/TypeScript
npm run lint
# ou
npx eslint src/ --max-warnings 0

# Python
ruff check .
# ou
flake8 src/
```

**Critério:** Zero erros de lint. Warnings opcionais dependendo do projeto.

---

### Phase 4: Test Suite
Executa testes com métricas de cobertura.

```bash
# Jest/Vitest
npm test -- --coverage
# ou
npx vitest run --coverage

# Python
pytest --cov=src --cov-report=term-missing
```

**Critério:** 80% de cobertura mínima. Todos os testes passando (zero failures).

---

### Phase 5: Security Scan
Busca por credenciais expostas e código de debug.

```bash
# Buscar por possíveis credenciais expostas
grep -r "sk-" src/ --include="*.ts" --include="*.py"
grep -r "api_key" src/ --include="*.ts" --include="*.py"
grep -r "password" src/ --include="*.env*"

# Buscar por console.log esquecido
grep -r "console\.log" src/ --include="*.ts" --include="*.tsx"

# Buscar por TODO de segurança
grep -r "TODO.*security\|FIXME.*auth\|HACK" src/
```

**Critério:** Nenhum segredo real exposto. Console.logs em produção devem ser removidos ou substituídos por logger.

---

### Phase 6: Diff Review
Revisão manual das mudanças antes de commitar.

```bash
# Ver todas as mudanças
git diff

# Ver apenas arquivos alterados
git diff --stat

# Ver staged changes
git diff --staged
```

**Critério:** Verificar manualmente:
- Sem mudanças não intencionais
- Error handling presente em paths críticos
- Edge cases cobertos
- Sem código comentado desnecessário

---

## Verification Report

Após rodar as 6 fases, produzir relatório padronizado:

```
## Verification Report — [timestamp]

Phase 1: Build         ✅ PASS / ❌ FAIL
Phase 2: Type Check    ✅ PASS / ❌ FAIL
Phase 3: Lint          ✅ PASS / ❌ FAIL
Phase 4: Tests         ✅ PASS (84% coverage) / ❌ FAIL (2 failures)
Phase 5: Security      ✅ PASS / ⚠️ WARN (1 console.log found)
Phase 6: Diff Review   ✅ CLEAN / ⚠️ REVIEW (3 files changed)

Issues to resolve:
- [list issues]

Ready to commit: YES / NO
```

## Usage Pattern

```
# Ao final de uma feature:
"Run verification loop"

# A cada 15 minutos em sessão longa:
"Checkpoint — run verification"

# Antes de commitar:
"Verify before commit"
```

## Integration with Hooks

Esta skill complementa PostToolUse hooks do Claude Code, adicionando verificação abrangente além da detecção imediata de problemas por ferramenta individual.

Para máxima cobertura, configure ambos:
- Hook: verificação imediata após cada ferramenta
- Esta skill: verificação holística no final da sessão

## Best Practices

- Sempre resolver falhas de **Phase 1 (Build)** antes de continuar
- Não commitar com falhas em **Phase 4 (Tests)**
- Tratar **Phase 5 (Security)** como blocker para credenciais reais
- **Phase 6 (Diff)** é a última linha de defesa — leia o diff com atenção
