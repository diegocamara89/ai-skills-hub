---
name: analise-contradicoes
description: >
  Esta skill deve ser usada quando o usuário pedir "analisar contradições",
  "confrontar depoimentos", "verificar inconsistências", "cruzar versões",
  "comparar o que cada um disse", "identificar mentiras", "preparar
  reperguntas", "qual depoimento é mais crível", ou quando o comando
  /contradicoes for invocado. Contém metodologia completa de análise lógica
  de contradições entre depoimentos, provas materiais e registros digitais,
  com ferramentas de classificação, avaliação de credibilidade e elaboração
  de roteiros de confronto para novas oitivas.
---

# Análise de Contradições Investigativas — Conhecimento Especializado

Skill de referência para identificação, classificação e exploração de contradições em inquéritos policiais.

## Fundamentos Teóricos da Análise de Contradições

### Por que contradições importam

Na investigação criminal, a contradição entre uma afirmação e uma prova objetiva é um dos instrumentos mais poderosos para:

1. **Demonstrar dolo** — quem mente sobre um fato central geralmente o faz porque a verdade o incrimina
2. **Destruir álibi** — contradição temporal/geográfica elimina a versão defensiva
3. **Revelar o mapa do crime** — as mentiras indicam exatamente o que o investigado quer ocultar
4. **Fortalecer a autoria** — multiplicidade de contradições críticas constitui conjunto indiciário robusto

### O Princípio da Mentira Orientada

Investigados mentem de forma *orientada* — as mentiras apontam para o que realmente aconteceu. Se alguém mente sobre onde estava em determinado horário, é porque estar naquele lugar o incrimina. Mapear as mentiras é mapear o crime.

### Tipos de Provas que Refutam Versões

| Tipo de Prova | Força Refutatória | Exemplo |
|--------------|------------------|---------|
| Laudo pericial | Máxima | IML, perícia de local, laudo de hardware |
| Registro digital (log, metadado) | Muito Alta | Log de IP, metadado de arquivo, geolocalização |
| Imagem (câmera, foto com metadado) | Muito Alta | Câmera de segurança, foto geotagueada |
| Extrato bancário / PIX | Alta | Transferência no horário que "estava dormindo" |
| Dado de ERB / geolocalização | Alta | Antena conectada 20km do local alegado |
| Testemunho múltiplo convergente | Alta | Três testemunhas independentes que confirmam |
| Documento oficial (certidão, contrato) | Alta | Assinatura em documento na data negada |
| Testemunho único | Média | Depende da credibilidade do depoente |
| Testemunho de cointeressado | Baixa | Exige confirmação por outros meios |

## Metodologia de Extração de Assertivas

### O que é uma assertiva verificável

Uma assertiva verificável é uma afirmação sobre:
- **Localização** em determinado momento ("estava em casa", "não fui ao local")
- **Conhecimento** de pessoas ou fatos ("não conheço", "nunca vi")
- **Participação** em eventos ("não fiz", "não estava presente")
- **Relações financeiras** ("nunca recebi", "não tenho conta nesse banco")
- **Comunicações** ("nunca falei com", "não tenho esse número")
- **Posse ou acesso** a objetos, contas, dispositivos ("não é meu", "não acesso")
- **Intenções** que possam ser verificadas por ações subsequentes

### O que NÃO é uma assertiva verificável (não inclluir na matriz)
- Opiniões e avaliações subjetivas ("achei que era legal")
- Justificativas e explicações ("eu pensei que...")
- Afirmações sobre intenções não verificáveis
- Declarações emocionais

## Classificação de Contradições — Referência Técnica

### Grau de Certeza da Contradição

Ao identificar uma contradição, classificar o **grau de certeza** com que ela existe:

| Grau | Descrição | Exemplo |
|------|-----------|---------|
| **Absoluta** | A prova objetiva torna a versão impossível | "Estava dormindo" vs. registro digital às 2h |
| **Forte** | A versão é altamente improvável diante da prova | "Não conheço X" vs. 847 trocas de mensagens |
| **Razoável** | A versão é inconsistente mas tem explicação alternativa | Horários imprecisos em depoimentos de memória |
| **Fraca** | Divergência que pode ser atribuída a erro de percepção | Detalhes periféricos (cor da roupa, dia da semana) |

**Instrução**: Apenas contradições **Absolutas** e **Fortes** devem ser elevadas ao status de indício relevante. Contradições **Fracas** são comuns em depoimentos honestos.

## Técnicas de Interrogatório Baseadas em Contradições

### Técnica de Revelação Progressiva

**Princípio**: Nunca revelar toda a prova de uma vez. Deixar o investigado aprofundar a mentira antes de apresentar a evidência decisiva.

**Sequência:**
1. Confirmar a versão original (sem confronto)
2. Aprofundar detalhes da versão falsa (criar comprometimento)
3. Introduzir dúvida com pergunta hipotética ("se houvesse uma câmera...")
4. Apresentar a prova parcialmente
5. Apresentar a prova completa após a tentativa de explicação

### Técnica PEACE (Preparation, Engage, Account, Closure, Evaluate)

Adaptada para o contexto brasileiro:

1. **Preparação**: dominar completamente todas as contradições antes da oitiva
2. **Engajamento**: rapport inicial, confirmar qualificação
3. **Relato livre**: deixar o investigado contar sua versão sem interrupção
4. **Confronto**: apresentar as contradições na ordem planejada (do menor para o maior impacto)
5. **Encerramento**: oferecer a oportunidade de esclarecimento final
6. **Avaliação**: documentar mudanças de versão

### Perguntas-Chave para Cada Tipo de Contradição

**Para contradição temporal:**
"O senhor disse que estava em [local X] às [hora]. Por que os registros telefônicos mostram que seu aparelho conectou à antena de [local Y] às [hora]?"

**Para contradição com extrato bancário:**
"O senhor afirmou que nunca recebeu dinheiro de [nome]. Como o senhor explica este crédito de R$ [valor] em [data] oriundo de CPF [número]?"

**Para contradição com testemunho:**
"O senhor disse que não conhece [nome]. Por que [testemunha] afirmou que os dois se encontraram em [local] em [data]?"

**Para contradição com câmera:**
"O senhor declarou que não esteve em [local] em [data]. Tenho aqui uma imagem de câmera de segurança de [local] no dia [data] às [hora]. O senhor reconhece esta imagem?"

## Avaliação de Credibilidade — Critérios Técnicos

### Indicadores de Depoimento Verdadeiro

- Consistência dos fatos centrais ao longo do tempo
- Inclusão espontânea de detalhes verificáveis
- Admissão de lapsos de memória em detalhes periféricos (normal e esperado)
- Correção espontânea de erros sem pressão
- Confirmação pelos outros elementos do conjunto probatório

### Indicadores de Depoimento Falso

- Mudança de versão sobre fatos centrais (especialmente após nova prova nos autos)
- Negativa absoluta de conhecer pessoas com quem há registro de contato
- Precisão seletiva: vago nos fatos incriminadores, detalhado nos aspectos favoráveis
- Versão que só se sustenta na ausência de prova objetiva
- Coincidência entre o momento da mudança de versão e a juntada de nova prova

## Referências Normativas e Jurisprudenciais

- **Art. 197, CPP**: A confissão do acusado não dispensa a prova — relevante para entender peso dos interrogatórios
- **Art. 202-225, CPP**: Regras gerais sobre testemunhas
- **Art. 226-228, CPP**: Reconhecimento de pessoas
- **Súmula 74, STJ**: Informante/testemunho único do cônjuge — cautela
- **Art. 155, CPP**: Prova ilícita — contamina as derivadas (teoria dos frutos da árvore envenenada)

Para casos com provas digitais, ver: `references/provas_digitais_admissibilidade.md`
