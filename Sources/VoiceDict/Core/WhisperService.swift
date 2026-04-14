import AVFoundation

class WhisperService {

    private let appSupport: URL
    private let serverBin: String
    private let cliBin: String
    private let modelPath: String
    private let serverPort = 8178

    private var serverProcess: Process?
    private var audioFile: AVAudioFile?
    private var audioFilePath: String?

    init() {
        appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceDict")
        serverBin = appSupport.appendingPathComponent("bin/whisper-server").path
        cliBin = appSupport.appendingPathComponent("bin/whisper-cli").path

        // Prefer small model (fast) — fallback to medium
        let modelsDir = appSupport.appendingPathComponent("models")
        let small = modelsDir.appendingPathComponent("ggml-small.bin").path
        let medium = modelsDir.appendingPathComponent("ggml-medium.bin").path
        modelPath = FileManager.default.fileExists(atPath: small) ? small : medium

        let modelName = (modelPath as NSString).lastPathComponent
        let hasServer = FileManager.default.fileExists(atPath: serverBin)
        Log.d("WhisperService: server=\(hasServer), model=\(modelName)")
    }

    // MARK: - Server lifecycle

    func startServer() {
        guard FileManager.default.fileExists(atPath: serverBin) else {
            Log.d("WhisperService: whisper-server não encontrado, usando CLI")
            return
        }
        guard serverProcess == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverBin)
        let nThreads = ProcessInfo.processInfo.activeProcessorCount
        process.arguments = [
            "-m", modelPath,
            "-l", "pt",
            "--no-timestamps",
            "-t", "\(nThreads)",
            "--flash-attn",
            "--port", "\(serverPort)",
            "--host", "127.0.0.1",
        ]
        process.environment = ProcessInfo.processInfo.environment
        process.environment?["GGML_METAL_LOG_LEVEL"] = "0"
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            Log.d("WhisperService: servidor iniciado (PID \(process.processIdentifier), porta \(serverPort))")

            // Wait for server to become ready
            DispatchQueue.global().async { [self] in
                for _ in 0..<40 { // up to 20 seconds
                    Thread.sleep(forTimeInterval: 0.5)
                    if self.isServerReady() {
                        Log.d("WhisperService: servidor pronto (modelo na GPU)")
                        return
                    }
                }
                Log.d("WhisperService: servidor não respondeu a tempo — fallback CLI")
            }
        } catch {
            Log.d("WhisperService: falha ao iniciar servidor: \(error)")
        }
    }

    func stopServer() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            Log.d("WhisperService: servidor parado")
        }
        serverProcess = nil
    }

    private func isServerReady() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { ok = true }
            sem.signal()
        }.resume()
        sem.wait()
        return ok
    }

    private var useServer: Bool {
        serverProcess?.isRunning == true && isServerReady()
    }

    // MARK: - Recording

    func startRecording(engine: AVAudioEngine) -> Bool {
        let tmpPath = NSTemporaryDirectory() + "voicedict_\(Int(Date().timeIntervalSince1970)).wav"

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

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
                } catch {}
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

    // MARK: - Transcription

    func stopAndTranscribe(engine: AVAudioEngine, completion: @escaping (String?) -> Void) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil

        guard let path = audioFilePath else {
            Log.d("WhisperService: sem arquivo de áudio")
            completion(nil)
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        Log.d("WhisperService: transcrevendo... WAV=\(fileSize) bytes")

        DispatchQueue.global().async { [self] in
            let start = CFAbsoluteTimeGetCurrent()

            let result: String?
            if self.useServer {
                result = self.transcribeViaServer(audioPath: path)
            } else {
                result = self.transcribeViaCLI(audioPath: path)
            }

            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

            // Keep last recording for debugging
            let debugPath = NSTemporaryDirectory() + "voicedict_last.wav"
            try? FileManager.default.removeItem(atPath: debugPath)
            try? FileManager.default.copyItem(atPath: path, toPath: debugPath)
            try? FileManager.default.removeItem(atPath: path)

            DispatchQueue.main.async {
                Log.d("WhisperService: resultado (\(elapsed)ms) = '\(result ?? "nil")'")
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

    // MARK: - Server-based transcription (fast — model already in GPU)

    private func transcribeViaServer(audioPath: String) -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/inference") else { return nil }

        let fileURL = URL(fileURLWithPath: audioPath)
        guard let fileData = try? Data(contentsOf: fileURL) else { return nil }

        let boundary = "VoiceDict-\(UUID().uuidString)"
        var body = Data()

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        // response_format field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        // language field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("pt\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let sem = DispatchSemaphore(value: 0)
        var result: String?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                Log.d("WhisperService [server]: erro HTTP: \(error.localizedDescription)")
                return
            }
            guard let data = data, let text = String(data: data, encoding: .utf8) else { return }
            result = self.cleanWhisperOutput(text)
        }.resume()

        sem.wait()
        return result
    }

    // MARK: - CLI-based transcription (fallback — slower, loads model each time)

    private func transcribeViaCLI(audioPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBin)
        let nThreads = ProcessInfo.processInfo.activeProcessorCount
        process.arguments = [
            "-m", modelPath,
            "-f", audioPath,
            "-l", "pt",
            "--no-timestamps",
            "-t", "\(nThreads)",
            "--beam-size", "1",
            "--flash-attn",
            "--no-prints",
        ]

        process.environment = ProcessInfo.processInfo.environment
        process.environment?["GGML_METAL_LOG_LEVEL"] = "0"

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()

            let timeoutWork = DispatchWorkItem {
                if process.isRunning {
                    Log.d("WhisperService [cli]: timeout 30s")
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutWork)
            process.waitUntilExit()
            timeoutWork.cancel()

            guard process.terminationStatus == 0 else {
                Log.d("WhisperService [cli]: status \(process.terminationStatus)")
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return cleanWhisperOutput(output)
        } catch {
            Log.d("WhisperService [cli]: falha: \(error)")
            return nil
        }
    }

    // MARK: - Output cleaning

    private func cleanWhisperOutput(_ raw: String) -> String? {
        var text = raw
        for token in ["[_EOT_]", "[_BEG_]", "[_SOT_]", "[_TT_", "[BLANK_AUDIO]", "(Se inscreva)", "(Obrigado por assistir)"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
