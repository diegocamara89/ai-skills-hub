# Artifact Triggers

## Deve sincronizar

Sincronize quando houver fonte concreta e rastreavel:

- relatorio de missao
- relatorio de diligencia
- oficio expedido ou resposta essencial
- representacao cautelar
- analise tecnica concluida
- achado probatorio estruturado

## Nao deve sincronizar

Nao sincronize:

- conversa exploratoria
- brainstorming
- rascunho incompleto
- texto sem origem verificavel
- narrativa pronta que ainda nao foi confrontada com a fonte

## Heuristica v1

- Se a fonte existe em arquivo, prefira `source_path`.
- Se o arquivo for `.docx`, extraia o texto e preserve `source_path`.
- Se a vinculacao do caso depender de adivinhacao, envie para inbox.
- Se a peca so repetir informacao ja registrada e o `source_key` for o mesmo, atualize sem duplicar.
