TASK_DONE:
- Pedido original conferido: sim
- Ambiente trabalhado: desenvolvimento (Mac local)
- Produção foi alterada: não se aplica (app pessoal)
- Se produção foi alterada, autorização explícita registrada: não se aplica
- Arquivos reais inspecionados: sim (StateMachine, WhisperService, HotkeyMonitor, Constants, TextInserter, build.sh, /tmp/ditado.log)
- Alterações feitas: sim
- Testes/validação executados: sim — swift build OK em 4s, app relançado, log mostra novo binário com event tap criado e uma transcrição bem-sucedida pós-deploy ("A mensagem não chegou no meu celular." em 709ms)
- Resultado: concluído
- Pendências reais: nenhuma identificada após validação. Próxima ditação real do Flávio confirma se as 3 fontes de falha silenciosa foram realmente cortadas.

### Arquivos alterados
- Sources/Ditado/Util/Constants.swift  (2 constantes ajustadas)
- Sources/Ditado/Core/WhisperService.swift  (guarda eng.isRunning antes de instalar tap)
- Sources/Ditado/Core/StateMachine.swift  (log explícito quando cooldown bloqueia)
- Ditado.app/Contents/MacOS/Ditado  (binário re-empacotado e re-assinado)

### O que foi preservado
- Toda a lógica de watchdog, observers de mudança de configuração e health timer
- Comportamento de prewarm, swap de tap, fallback CLI, prompt hint dinâmico, correções
- TextInserter (sem mudança no código — só o delay externo)
- Resources/Info.plist, fluxo do build.sh, scripts auxiliares

### O que foi acrescentado
- Em `Constants.swift`:
  - `clipboardRestoreDelay`: 0.100 → 0.600 (impede que apps lentos colem o conteúdo restaurado em vez do texto ditado)
  - `cooldownDuration`: 0.300 → 0.050 (libera ditados em sequência rápida)
  - Comentários explicando os números
- Em `WhisperService.startRecording`: bloco que verifica `eng.isRunning` e religa antes de instalar o tap de gravação (motor pausado pelo macOS deixava o tap mudo)
- Em `StateMachine.handleHotkeyEvent`: log "⚠️ Cooldown bloqueou ativação (...)" quando o press é descartado pelo cooldown — futuro debug fica visível em /tmp/ditado.log

### Validação executada
- `swift build -c release` → Build complete! (4.16s), sem warning
- `pkill` do Ditado antigo + `cp` do .build/release/Ditado para Ditado.app/Contents/MacOS/Ditado
- `xattr -cr` no .app + `codesign --force --sign -` (identifier voltou pra `com.user.ditado`)
- `tccutil reset Accessibility com.user.ditado` + abertura do painel de Privacidade
- `open Ditado.app` → log mostra: `AX trusted: true`, `Event tap CRIADO com sucesso!`, primeiro ditado pós-deploy gravado e transcrito em 709ms

### Checagem contra o pedido original
- "audite" → 3 fontes de falha silenciosa identificadas (área de transferência restaurada cedo demais; cooldown engolindo retentativa rápida; motor pausado sem checagem)
- "arrume" → 3 correções aplicadas, recompiladas e instaladas
- "rápido" → ~4 minutos do diagnóstico até o app relançado

### Pendências ou riscos
Nenhuma pendência identificada após a validação executada.

Risco residual conhecido (NÃO endereçado nesta rodada porque seria mexer no fluxo de áudio durante captura — risco maior que benefício):
- Se o macOS disparar `AVAudioEngineConfigurationChange` durante uma ditação (você conecta AirPods, conecta fones, troca de saída/entrada), o áudio em andamento É descartado silenciosamente. Comportamento atual: pressionou, falou, soltou, nada aparece. Se acontecer de novo, dá pra adicionar feedback sonoro nesse caminho — me chama.
