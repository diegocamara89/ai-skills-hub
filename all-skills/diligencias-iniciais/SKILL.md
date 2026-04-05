---
name: diligencias-iniciais
description: >
  Esta skill deve ser usada quando o usuário pedir "planejar diligências",
  "quais diligências devo fazer", "como investigar esse crime", "próximos
  passos investigativos", "roteiro de investigação", "diligências prioritárias",
  "o que requisitar", "como obter a prova", ou quando o comando /diligencias
  for invocado. Contém repertório completo de diligências por tipo penal,
  fundamentos legais de cada requisição, e critérios de priorização
  para qualquer fase da investigação policial.
---

# Diligências Investigativas — Conhecimento Especializado

Skill de referência para planejamento e priorização de diligências policiais em qualquer fase investigativa.

## Princípios de Priorização

Ao organizar um plano de diligências, aplicar obrigatoriamente a **Matriz de Priorização Investigativa**:

| Critério | Peso | Avaliação |
|----------|------|-----------|
| Impacto na materialidade | Alto | ✅ Materialidade / ⚠️ Suporte / ❌ Acessório |
| Impacto na autoria | Alto | ✅ Direta / ⚠️ Indireta / ❌ Periférica |
| Risco de perecimento | Crítico | 🔴 Imediato / 🟡 Breve / 🟢 Estável |
| Prazo prescricional | Crítico | Calcular dias restantes |
| Complexidade/tempo de retorno | Médio | Alta / Média / Baixa |
| Custo operacional | Baixo | Alto / Médio / Baixo |

**Prioridade máxima sempre para:**
1. Diligências com risco iminente de perecimento da prova (câmeras, logs digitais, arquivos temporários)
2. Situações com prazo prescricional próximo
3. Medidas cautelares urgentes (quando houver risco de fuga ou destruição de provas)

## Prazos de Preservação de Dados — Referência Crítica

| Tipo de Dado | Prazo Legal de Preservação | Fundamento |
|-------------|--------------------------|-----------|
| Registros de conexão (IP/porta) | 1 ano | Art. 13, Marco Civil |
| Registros de acesso a aplicações | 6 meses | Art. 15, Marco Civil |
| Dados de aplicativos (requisição) | Guardar após requisição policial | Art. 13, §2º, Marco Civil |
| Imagens de câmeras de segurança (privadas) | Sem obrigação — solicitar urgentemente | Prática forense |
| Extratos bancários | 5 a 10 anos (depende da instituição) | Resolução CMN |
| Logs de ERB (telefonia) | 5 anos (Lei Geral de Telecom) | Lei 9.472/97 |
| Registros de PIX | 5 anos | Regulação BCB |

**URGÊNCIA MÁXIMA**: Imagens de câmeras privadas (lojas, residências, postos) devem ser solicitadas/preservadas em até 48-72 horas após os fatos.

## Catálogo de Diligências por Tipo Penal

### A. Crimes Financeiros e Patrimoniais

#### A.1 Estelionato e Fraude Eletrônica
Ver referência completa: `references/diligencias_crimes_financeiros.md`

**Diligências imediatas (até 48h):**
- Preservação de logs de IP (requisição ao provedor — art. 13, Marco Civil)
- Bloqueio de transferência via BACENJUD (se flagrante ou com autorização)
- Preservação de prints / capturas de tela com metadados

**Diligências de curto prazo (até 15 dias):**
- Identificação do IP → titular (requisição ANATEL + operadora)
- Dados cadastrais da conta receptora (BACENJUD / banco)
- CPF/CNPJ do beneficiário da transferência (Receita Federal)
- Oitiva da(s) vítima(s)

**Diligências estratégicas:**
- RIF/COAF (se movimentação suspeita)
- Análise de outros golpes com mesmo modus operandi (vinculação de casos)

#### A.2 Lavagem de Dinheiro
Ver referência completa: `references/diligencias_lavagem.md`

**Checklist obrigatório:**
- [ ] Solicitação de RIF ao COAF (art. 15, Lei 9.613/98)
- [ ] Quebra de sigilo bancário (judicial) de todas as contas identificadas
- [ ] Quebra de sigilo fiscal (Receita Federal) — requer autorização judicial
- [ ] Investigação de pessoas jurídicas vinculadas (Junta Comercial + Receita)
- [ ] Rastreamento de bens: imóveis (IRTDPJ), veículos (DETRAN/SENATRAN), aeronaves (ANAC)
- [ ] Análise de RAIS/CAGED (compatibilidade com renda declarada)
- [ ] Análise de IT/IRPF dos últimos 5 anos

#### A.3 Crimes Contra a Administração Pública / Licitações
Ver referência completa: `references/diligencias_corrupcao.md`

**Obter prioritariamente:**
- Processo licitatório completo (edital, propostas, atas, contratos, liquidação, pagamento)
- Extratos do SIAFI / SIAFEM
- Laudo pericial de superfaturamento (perito contábil ou engenheiro)
- Comparativo de preços SINAPI/SICRO/PNCP
- Análise de vínculos societários entre empresas concorrentes

### B. Crimes Contra a Pessoa Digital

#### B.1 Crimes Cibernéticos
**Diligências imediatas (até 24h):**
- Preservação de logs (art. 13, Marco Civil — 15 dias de prazo para o provedor)
- Extração forense do dispositivo vítima (com autorização)
- Hash dos arquivos (cadeia de custódia digital)

**Diligências de curto prazo:**
- Identificação do IP → titular (ANATEL + operadora)
- Requisição de dados ao WhatsApp/Facebook/Google (Marco Civil + MLAT se necessário)
- Análise de malware (perícia)

### C. Organização Criminosa

**Checklist dos meios especiais (art. 3º, Lei 12.850/2013):**
- [ ] Interceptação telefônica (Lei 9.296/96) — requer autorização judicial
- [ ] Interceptação telemática — requer autorização judicial
- [ ] Colaboração premiada (art. 4º, Lei 12.850/2013)
- [ ] Captação ambiental (art. 3º, III) — requer autorização judicial
- [ ] Infiltração policial (art. 10-A) — requer autorização judicial + relatório
- [ ] Vigilância e monitoramento (não requer autorização judicial)
- [ ] Levantamento patrimonial de todos os membros

## Fundamentos Legais por Tipo de Diligência

### Requisição Direta (sem autorização judicial)
- **Fundamento**: Art. 3º, Lei 12.830/2013 — O delegado pode requisitar informações de qualquer pessoa ou entidade pública ou privada
- **Aplicável a**: dados cadastrais, certidões, registros públicos, dados de qualificação

### Requisição a Provedores de Internet
- **Fundamento**: Art. 13 e 22, Lei 12.965/2014 (Marco Civil)
- **Prazo**: mínimo 15 dias para preservação após requisição policial
- **Aplicável a**: IP de origem, dados de conexão, registros de acesso

### Quebra de Sigilo Bancário
- **Fundamento**: Art. 3º, LC 105/2001
- **Requer**: autorização judicial prévia (via BACENJUD)
- **Aplicável a**: extratos, movimentações, dados de contas

### Quebra de Sigilo Telefônico (cadastral — sem interceptação)
- **Fundamento**: Art. 3º, Lei 12.830/2013
- **Requer**: requisição direta à operadora (dados cadastrais, STFC, ERBs)
- **Aplicável a**: titular do número, endereço cadastral, histórico de ERBs

### Interceptação Telefônica
- **Fundamento**: Lei 9.296/96
- **Requer**: autorização judicial, indícios de autoria, impossibilidade de prova por outros meios, crime punido com reclusão
- **Prazo**: 15 dias, renovável por igual período

### Sequestro e Arresto de Bens
- **Fundamento**: Arts. 125-132, CPP; Art. 4º, Lei 9.613/98
- **Requer**: autorização judicial mediante representação fundamentada
- **Aplicável a**: bens relacionados ao crime ou adquiridos com produto do crime

## Modelos de Peças Processuais

Para modelos detalhados de ofícios, representações e requisições, ver:
- `references/modelos_oficios.md`
- `references/modelos_representacoes.md`
