import AVFoundation

// MARK: - Dictation state

enum DictationState {
    case idle
    case activating
    case listening
    case processing
}

// MARK: - Central state machine

class StateMachine {

    private(set) var state: DictationState = .idle
    var onStateChanged: ((DictationState) -> Void)?
    /// Texto final inserido (já com correções aplicadas). Usado pela CorrectionsWindow.
    var onTranscription: ((String) -> Void)?

    private let whisperService = WhisperService()
    private let textInserter = TextInserter()
    let hotkeyMonitor = HotkeyMonitor()

    private var activationWork: DispatchWorkItem?
    private var lastProcessingEndTime: Date = .distantPast

    // Watchdog: detecta state machine travado (ex: AVAudioEngine.installTap pendurou).
    // Estados transitórios não devem durar mais que algumas centenas de ms (.activating)
    // ou poucos segundos (.processing). Se exceder, força recuperação completa.
    private var watchdog: DispatchWorkItem?
    private static let activatingMaxDuration: TimeInterval = 2.0    // 80ms esperado, 2s = margem 25x
    private static let processingMaxDuration: TimeInterval = 35.0   // server timeout 15s + CLI fallback 30s

    // MARK: Lifecycle

    func start() {
        whisperService.startServer()

        // Inicia engine persistente na main thread.
        // Bloqueia 200-2000ms para inicializar hardware de áudio — feito uma vez só no startup.
        // A partir daí, todas as ditações usam swap de tap (instantâneo, sem cold start).
        whisperService.startEngine()

        // Aquece converter + file I/O para que o primeiro aperto não perca ~100ms.
        whisperService.prewarmRecording()

        hotkeyMonitor.onEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        hotkeyMonitor.start()

        Log.d("StateMachine iniciada (Whisper). Segure L-Shift + L-Control para ditar.")
    }

    func stop() {
        hotkeyMonitor.stop()
        whisperService.cancel()
        whisperService.stopServer()
        whisperService.stopEngine()
    }

    // MARK: Event handling

    func handleHotkeyEvent(_ event: HotkeyEvent) {
        Log.d("Event: \(event) | State: \(state)")

        switch (state, event) {
        case (.idle, .bothModifiersPressed):
            let elapsed = Date().timeIntervalSince(lastProcessingEndTime)
            guard elapsed >= Config.cooldownDuration else {
                Log.d("⚠️ Cooldown bloqueou ativação (\(Int(elapsed * 1000))ms < \(Int(Config.cooldownDuration * 1000))ms)")
                return
            }
            transitionToActivating()

        case (.activating, .modifierReleased),
             (.activating, .nonModifierKeyDown),
             (.activating, .additionalModifierDetected):
            Log.d("Cancelando ativação: \(event)")
            cancelActivation()

        case (.listening, .modifierReleased):
            transitionToProcessing()

        default:
            break
        }
    }

    // MARK: State transitions

    private func transitionToActivating() {
        Log.d("→ ACTIVATING")
        state = .activating
        hotkeyMonitor.isActivating = true
        onStateChanged?(.activating)
        armWatchdog(after: StateMachine.activatingMaxDuration, expected: .activating)

        // Inicia gravação IMEDIATAMENTE via swap de tap (instantâneo — engine já está rodando).
        // A primeira palavra é capturada desde o keypress, sem cold start.
        let activationStart = Date()
        let started = whisperService.startRecording()
        if !started {
            Log.d("Áudio falhou — voltando a idle")
            cancelWatchdog()
            state = .idle
            onStateChanged?(.idle)
            return
        }

        let elapsed = Date().timeIntervalSince(activationStart)
        Log.d("gravação iniciada em \(Int(elapsed * 1000))ms")

        // Desconta do activation delay o tempo já decorrido em startRecording()
        let remainingDelay = max(0, Config.activationDelay - elapsed)
        activationWork = DispatchWorkItem {}
        let work = activationWork
        DispatchQueue.global().async { [weak self] in
            if remainingDelay > 0 {
                Thread.sleep(forTimeInterval: remainingDelay)
            }
            guard let work = work, !work.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self = self, self.state == .activating else { return }
                self.transitionToListening()
            }
        }
    }

    private func cancelActivation() {
        // CRÍTICO: resetar estado ANTES da limpeza de áudio.
        // Se whisperService.cancel() pendurar (ex: AVAudioEngine corrompido),
        // o estado já está em .idle e a próxima ativação funciona normalmente.
        activationWork?.cancel()
        activationWork = nil
        cancelWatchdog()
        hotkeyMonitor.isActivating = false
        state = .idle
        onStateChanged?(.idle)
        whisperService.cancel()  // Remove tap de gravação e reinstala tap silencioso
    }

    private func transitionToListening() {
        Log.d("→ LISTENING (gravação em andamento)")
        activationWork = nil
        cancelWatchdog()
        hotkeyMonitor.isActivating = false
        state = .listening
        onStateChanged?(.listening)
        // Engine e gravação já ativos desde transitionToActivating()
    }

    private func transitionToProcessing() {
        Log.d("→ PROCESSING (transcrevendo com Whisper)")
        state = .processing
        onStateChanged?(.processing)
        armWatchdog(after: StateMachine.processingMaxDuration, expected: .processing)

        whisperService.stopAndTranscribe { [weak self] text in
            guard let self = self, self.state == .processing else { return }
            self.cancelWatchdog()
            self.lastProcessingEndTime = Date()

            if let text = text, !text.isEmpty {
                let corrected = CorrectionsStore.shared.apply(text)
                if corrected != text {
                    Log.d("Whisper resultado: '\(text)' → corrigido: '\(corrected)'")
                } else {
                    Log.d("Whisper resultado: '\(text)'")
                }
                self.onTranscription?(corrected)
                self.textInserter.insert(corrected)
            } else {
                Log.d("Whisper: sem texto detectado")
            }

            self.state = .idle
            self.onStateChanged?(.idle)
        }
    }

    // MARK: - Watchdog (auto-recuperação)

    /// Agenda watchdog para detectar state machine travado em estado transitório.
    /// Se após `timeout` o estado ainda for `expected`, dispara forceRecover.
    /// Roda em queue de background para sobreviver caso a main thread esteja bloqueada
    /// por algum AVAudioEngine.installTap pendurado.
    private func armWatchdog(after timeout: TimeInterval, expected: DictationState) {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.state == expected else { return }
            Log.d("⚠️ WATCHDOG: travado em \(expected) por \(timeout)s — forçando recuperação")
            self.forceRecover(from: expected)
        }
        watchdog = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// Recuperação completa: reseta estado imediatamente (sem depender de cleanup de áudio)
    /// e dispara reconstrução do AVAudioEngine para limpar qualquer corrupção.
    /// Chamado pelo watchdog quando detecta travamento.
    private func forceRecover(from stuckState: DictationState) {
        // 1. Reset imediato do estado — leitura/escrita de enum é atômica.
        //    Isso garante que a próxima hotkey funcionará mesmo se o áudio estiver pendurado.
        activationWork?.cancel()
        activationWork = nil
        hotkeyMonitor.isActivating = false
        state = .idle
        onStateChanged?(.idle)

        // 2. Reconstrói engine de áudio do zero (em main, não-bloqueante).
        //    Se o engine estava corrompido após .AVAudioEngineConfigurationChange,
        //    isso restaura o pipeline de áudio para a próxima ditação.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Log.d("forceRecover: rebuild do AVAudioEngine")
            self.whisperService.rebuildEngine()
        }
    }
}
