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

    private var audioEngine: AVAudioEngine?
    private var warmEngine: AVAudioEngine? // Pre-created engine for fast start
    private var activationWork: DispatchWorkItem?
    private var lastProcessingEndTime: Date = .distantPast

    // MARK: Lifecycle

    func start() {
        whisperService.startServer()

        hotkeyMonitor.onEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        hotkeyMonitor.start()

        // Pre-aquece engine em background: chama engine.start() para inicializar
        // o hardware de áudio antes do usuário precisar gravar. Quando startRecording()
        // for chamado, engine.isRunning == true e pula o engine.start() (194-344ms).
        prepareWarmEngine()
    }

    func stop() {
        hotkeyMonitor.stop()
        cancelActivation()
        whisperService.stopServer()
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

    // MARK: Engine pre-warming

    /// Cria e pré-inicia o AVAudioEngine na main thread (AVAudioEngine não é thread-safe).
    /// O dispatch async garante que não bloqueia o caller. O engine.start() é chamado em idle,
    /// eliminando o cold start de 194-344ms quando o usuário ativar a ditação.
    private func prepareWarmEngine() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let engine = AVAudioEngine()
            do {
                // Inicia o engine (sem tap) para inicializar a sessão de áudio do sistema.
                // Nota: NÃO acessa inputNode antes de installTap — pode causar crash ObjC.
                try engine.start()
                self.warmEngine = engine
                Log.d("AudioEngine pré-aquecido ✓")
            } catch {
                // Falha silenciosa — startRecording() fará cold start normalmente
                Log.d("AudioEngine pré-aquecimento falhou: \(error) — usará cold start")
            }
        }
    }

    // MARK: State transitions

    private func transitionToActivating() {
        Log.d("→ ACTIVATING")
        state = .activating
        hotkeyMonitor.isActivating = true
        onStateChanged?(.activating)

        activationWork = DispatchWorkItem {}
        let work = activationWork
        DispatchQueue.global().async { [weak self] in
            Thread.sleep(forTimeInterval: Config.activationDelay)
            guard let work = work, !work.isCancelled else { return }
            DispatchQueue.main.async {
                Log.d("⏱ 180ms atingido!")
                guard let self = self, self.state == .activating else { return }
                self.transitionToListening()
            }
        }
    }

    private func cancelActivation() {
        activationWork?.cancel()
        activationWork = nil
        hotkeyMonitor.isActivating = false
        whisperService.cancel()
        audioEngine?.stop()
        audioEngine = nil
        state = .idle
        onStateChanged?(.idle)
    }

    private func transitionToListening() {
        Log.d("→ LISTENING")
        activationWork = nil
        hotkeyMonitor.isActivating = false
        state = .listening
        onStateChanged?(.listening)

        // Usa engine pré-aquecido (já com hardware inicializado) se disponível.
        // startRecording() detecta engine.isRunning e pula engine.start() — gravação
        // começa em <50ms em vez de 194-344ms (cold start).
        let engine = warmEngine ?? AVAudioEngine()
        warmEngine = nil
        audioEngine = engine

        let started = whisperService.startRecording(engine: engine)
        if !started {
            Log.d("Áudio falhou — voltando a idle")
            audioEngine = nil
            state = .idle
            onStateChanged?(.idle)
        }
    }

    private func transitionToProcessing() {
        Log.d("→ PROCESSING (transcrevendo com Whisper)")
        state = .processing
        onStateChanged?(.processing)

        guard let engine = audioEngine else {
            state = .idle
            onStateChanged?(.idle)
            return
        }

        whisperService.stopAndTranscribe(engine: engine) { [weak self] text in
            guard let self = self, self.state == .processing else { return }
            self.lastProcessingEndTime = Date()
            self.audioEngine = nil

            if let text = text, !text.isEmpty {
                Log.d("Whisper resultado: '\(text)'")
                self.textInserter.insert(text)
            } else {
                Log.d("Whisper: sem texto detectado")
            }

            self.state = .idle
            self.onStateChanged?(.idle)

            // Pré-aquece engine para a próxima gravação (background).
            // Mantém hardware de áudio inicializado para que a próxima
            // gravação comece imediatamente sem cold start.
            self.prepareWarmEngine()
        }
    }
}
