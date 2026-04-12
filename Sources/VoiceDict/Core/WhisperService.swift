import AVFoundation

class WhisperService {

    private let whisperBin: String
    private let modelPath: String
    private var audioFile: AVAudioFile?
    private var audioFilePath: String?

    init() {
        // Paths relative to the app bundle's parent (or absolute for dev)
        let base = "/Users/imac/sistemas pequenos - ferramentas/voicedict/vendor/whisper.cpp"
        whisperBin = "\(base)/build/bin/whisper-cli"
        modelPath = "\(base)/models/ggml-medium.bin"

        Log.d("WhisperService: bin=\(FileManager.default.fileExists(atPath: whisperBin)), model=\(FileManager.default.fileExists(atPath: modelPath))")
    }

    /// Start recording to a WAV file. Call from main thread.
    func startRecording(engine: AVAudioEngine) -> Bool {
        let tmpPath = NSTemporaryDirectory() + "voicedict_\(Int(Date().timeIntervalSince1970)).wav"

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Whisper needs 16kHz mono — set up converter
        guard let wavFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            Log.d("WhisperService: falha ao criar formato WAV")
            return false
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: wavFormat) else {
            Log.d("WhisperService: falha ao criar converter (\(inputFormat) → \(wavFormat))")
            return false
        }

        do {
            audioFile = try AVAudioFile(forWriting: URL(fileURLWithPath: tmpPath), settings: wavFormat.settings)
            audioFilePath = tmpPath
        } catch {
            Log.d("WhisperService: falha ao criar arquivo: \(error)")
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let file = self.audioFile else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: wavFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, convertedBuffer.frameLength > 0 {
                do {
                    try file.write(from: convertedBuffer)
                } catch {
                    // Silently skip write errors
                }
            }
        }

        do {
            try engine.start()
            Log.d("WhisperService: gravando em \(tmpPath)")
            return true
        } catch {
            Log.d("WhisperService: falha ao iniciar engine: \(error)")
            inputNode.removeTap(onBus: 0)
            return false
        }
    }

    /// Stop recording and transcribe. Calls completion on main thread.
    func stopAndTranscribe(engine: AVAudioEngine, completion: @escaping (String?) -> Void) {
        // Stop recording
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil // flush and close

        guard let path = audioFilePath else {
            Log.d("WhisperService: sem arquivo de áudio")
            completion(nil)
            return
        }

        Log.d("WhisperService: transcrevendo...")

        // Run whisper-cli in background
        DispatchQueue.global().async { [self] in
            let result = self.runWhisper(audioPath: path)

            // Cleanup temp file
            try? FileManager.default.removeItem(atPath: path)

            DispatchQueue.main.async {
                Log.d("WhisperService: resultado = '\(result ?? "nil")'")
                completion(result)
            }
        }

        audioFilePath = nil
    }

    func cancel() {
        if let path = audioFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        audioFile = nil
        audioFilePath = nil
    }

    private func runWhisper(audioPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBin)
        process.arguments = [
            "-m", modelPath,
            "-f", audioPath,
            "-l", "pt",           // Portuguese
            "--no-timestamps",    // Clean output without timestamps
            "-t", "4",            // 4 threads
            "--print-special", "false",
        ]

        // Suppress Metal/GPU debug logs
        process.environment = ProcessInfo.processInfo.environment
        process.environment?["GGML_METAL_LOG_LEVEL"] = "0"

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Clean whisper output: remove special tokens and trim
            var text = output
            // Remove Whisper special tokens
            for token in ["[_EOT_]", "[_BEG_]", "[_SOT_]", "[_TT_", "[BLANK_AUDIO]", "(Se inscreva)", "(Obrigado por assistir)"] {
                text = text.replacingOccurrences(of: token, with: "")
            }
            // Remove any remaining [tags]
            text = text.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
            // Remove any remaining (hallucinated subtitles)
            text = text.replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            Log.d("WhisperService: falha ao executar: \(error)")
            return nil
        }
    }
}
