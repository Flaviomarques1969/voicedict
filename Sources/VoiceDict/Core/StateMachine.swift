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
    private var activationWork: DispatchWorkItem?
    private var lastProcessingEndTime: Date = .distantPast

    // MARK: Lifecycle

    func start() {
        hotkeyMonitor.onEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        hotkeyMonitor.start()
    }

    func stop() {
        hotkeyMonitor.stop()
        cancelActivation()
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

        let engine = AVAudioEngine()
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
        }
    }
}
