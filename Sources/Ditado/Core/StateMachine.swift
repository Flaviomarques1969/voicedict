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

    private let whisperService = WhisperService()
    private let textInserter = TextInserter()
    let hotkeyMonitor = HotkeyMonitor()

    private var activationWork: DispatchWorkItem?
    private var lastProcessingEndTime: Date = .distantPast

    // MARK: Lifecycle

    func start() {
        whisperService.startServer()

        // Inicia engine persistente na main thread.
        // Bloqueia 200-2000ms para inicializar hardware de áudio — feito uma vez só no startup.
        // A partir daí, todas as ditações usam swap de tap (instantâneo, sem cold start).
        whisperService.startEngine()

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
            guard Date().timeIntervalSince(lastProcessingEndTime) >= Config.cooldownDuration else { return }
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

        // Inicia gravação IMEDIATAMENTE via swap de tap (instantâneo — engine já está rodando).
        // A primeira palavra é capturada desde o keypress, sem cold start.
        let activationStart = Date()
        let started = whisperService.startRecording()
        if !started {
            Log.d("Áudio falhou — voltando a idle")
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
        activationWork?.cancel()
        activationWork = nil
        hotkeyMonitor.isActivating = false
        whisperService.cancel()  // Remove tap de gravação e reinstala tap silencioso
        state = .idle
        onStateChanged?(.idle)
    }

    private func transitionToListening() {
        Log.d("→ LISTENING (gravação em andamento)")
        activationWork = nil
        hotkeyMonitor.isActivating = false
        state = .listening
        onStateChanged?(.listening)
        // Engine e gravação já ativos desde transitionToActivating()
    }

    private func transitionToProcessing() {
        Log.d("→ PROCESSING (transcrevendo com Whisper)")
        state = .processing
        onStateChanged?(.processing)

        whisperService.stopAndTranscribe { [weak self] text in
            guard let self = self, self.state == .processing else { return }
            self.lastProcessingEndTime = Date()

            if let text = text, !text.isEmpty {
                Log.d("Whisper resultado: '\(text)'")
                self.textInserter.insert(text)
            } else {
                Log.d("Whisper: sem texto detectado")
            }

            self.state = .idle
            self.onStateChanged?(.idle)
        }
    }
}
