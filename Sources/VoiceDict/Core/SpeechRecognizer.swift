import Speech

// MARK: - Result type

enum RecognitionResult {
    case success(String)
    case error(partialText: String?)
}

// MARK: - Speech recognizer wrapper

class SpeechRecognizer {

    var onResult: ((RecognitionResult) -> Void)?
    private(set) var lastPartialText: String?

    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasDeliveredResult = false

    init() {
        recognizer = SFSpeechRecognizer(locale: Config.speechLocale)
        recognizer?.defaultTaskHint = .dictation
        Log.d("SpeechRecognizer: locale=\(Config.speechLocale.identifier), available=\(recognizer?.isAvailable ?? false), supportsOnDevice=\(recognizer?.supportsOnDeviceRecognition ?? false)")
    }

    func preloadModel() {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            Log.d("SpeechRecognizer: preload skipped (unavailable)")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        let t = recognizer.recognitionTask(with: req) { _, _ in }
        req.endAudio()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { t.cancel() }
    }

    func prepareRequest() {
        lastPartialText = nil
        hasDeliveredResult = false

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation

        // Use on-device only if supported, otherwise allow network
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
            Log.d("STT: modo on-device")
        } else {
            Log.d("STT: modo com rede (on-device não suportado para \(Config.speechLocale.identifier))")
        }
        request = req

        guard let recognizer = recognizer, recognizer.isAvailable else {
            Log.d("STT: recognizer indisponível!")
            // Deliver error immediately
            DispatchQueue.main.async { [weak self] in
                self?.onResult?(.error(partialText: nil))
            }
            return
        }

        Log.d("STT: iniciando recognition task")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !self.hasDeliveredResult else { return }

                if let result = result {
                    self.lastPartialText = result.bestTranscription.formattedString
                    Log.d("STT parcial: '\(result.bestTranscription.formattedString)'")
                    if result.isFinal {
                        self.hasDeliveredResult = true
                        Log.d("STT final: '\(result.bestTranscription.formattedString)'")
                        self.onResult?(.success(result.bestTranscription.formattedString))
                    }
                }

                if let error = error, !self.hasDeliveredResult {
                    Log.d("STT erro: \(error.localizedDescription)")
                    self.hasDeliveredResult = true
                    self.onResult?(.error(partialText: self.lastPartialText))
                }
            }
        }
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func finalize() {
        Log.d("STT: finalizando (endAudio)")
        request?.endAudio()
    }

    func cancelRequest() {
        task?.cancel()
        task = nil
        request = nil
        lastPartialText = nil
        hasDeliveredResult = false
    }
}
