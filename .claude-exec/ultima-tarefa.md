TASK_INIT (2026-06-20):
- Protocolo carregado: sim
- Padrões carregados: sim
- Ambiente alvo: desenvolvimento (app pessoal Mac local — não há produção protegida)
- Produção protegida: sim (não se aplica a este app)
- Autorização para produção: não se aplica
- Pedido entendido: descobrir por que o Ditado.app (ditado por voz) parou de funcionar.
- Critério de conclusão: causa objetiva identificada com evidência + app voltando a operar.

TASK_DONE (2026-06-20):
- Pedido original conferido: sim
- Ambiente trabalhado: desenvolvimento (Mac local)
- Produção foi alterada: não (app pessoal)
- Se produção foi alterada, autorização explícita registrada: não se aplica
- Arquivos reais inspecionados: sim (HotkeyMonitor.swift, Constants.swift, WhisperService.swift, README, git log/status, /tmp/ditado.log, processos do sistema)
- Alterações feitas: sim — apenas operacional (matar motor órfão + reabrir app). NENHUM arquivo de código alterado nesta rodada.
- Testes/validação executados: sim — app reaberto (pid 98311), whisper-server novo (pid 98315, porta 8178, HTTP 200), log confirma "Event tap CRIADO com sucesso!" + "AX trusted: true" + "StateMachine iniciada. Segure L-Shift + L-Control para ditar."
- Resultado: concluído (causa raiz identificada e app operante); 1 ponto de uso a confirmar com o Flávio (combinação de teclas)
- Pendências reais: confirmar com Flávio se ele estava apertando Shift+Command em vez de Shift+Control, ou se o Control está remapeado no macOS.

### Diagnóstico (por que não funcionava)
1. CAUSA IMEDIATA: o app da barra de menus (Ditado) NÃO estava em execução. Sem ele, a tecla de atalho não é escutada e nada acontece. O whisper-server (motor) tinha ficado órfão, de pé há 1 dia e 5 horas, sem o app.
2. CAUSA DE USO (evidência no log da última sessão): a combinação que ARMA o ditado é Left Shift + Left Control. O código IGNORA de propósito qualquer combinação que inclua Command (HotkeyMonitor.swift:145-151: `extraModifiers = ... || anyCommand`). O log mostrava o Flávio apertando "L-SHIFT + L-CMD" (Shift + Command), que cai sempre em `modifierReleased | State: idle` — nunca grava.

### Correção aplicada (operacional, reversível)
- `kill 37882` (whisper-server órfão) + `open Ditado.app`.
- App subiu limpo; motor novo pronto na GPU; event tap criado; acessibilidade OK.

### O que NÃO foi mexido
- Código-fonte: intocado. Continua a alteração NÃO COMMITADA em WhisperService.swift (filtro de alucinação + restart incondicional do servidor) de sessão anterior — o binário instalado (16/05 10:48) já foi compilado com ela, mas ela nunca foi registrada no git. Preservada como está.

### Pendências ou riscos
- Confirmar combinação de teclas com o Flávio (Shift+Control, não Command).
- Risco residual antigo (não endereçado): troca de áudio (AirPods/fones) durante uma ditação descarta o áudio silenciosamente.

--- TAREFA ANTERIOR (16/05/2026) preservada abaixo ---
TASK_DONE: auditoria + correção de 3 fontes de falha silenciosa (clipboardRestoreDelay 0.100→0.600; cooldownDuration 0.300→0.050; checagem eng.isRunning antes do tap). Build OK, app reinstalado e validado com ditado de 709ms. Detalhe completo no histórico do git e nas mensagens da sessão.
