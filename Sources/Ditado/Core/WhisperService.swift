import AVFoundation

class WhisperService {

    private let appSupport: URL
    private let serverBin: String
    private let cliBin: String
    private let modelPath: String
    private let serverPort = 8178

    private var serverProcess: Process?
    // _serverReady acessado de múltiplas threads (terminationHandler, startup loop, main).
    // serverLock serializa todas as leituras/escritas para evitar race condition.
    private let serverLock = NSLock()
    private var _serverReady = false
    private var serverReady: Bool {
        get { serverLock.lock(); defer { serverLock.unlock() }; return _serverReady }
        set { serverLock.lock(); defer { serverLock.unlock() }; _serverReady = newValue }
    }

    // Engine persistente — fica rodando o tempo todo com tap silencioso.
    // Na gravação, o tap silencioso é trocado pelo tap de gravação (swap instantâneo).
    // Elimina o cold start de engine.start() (200-2000ms) no momento da ditação.
    private var engine: AVAudioEngine?
    private var persistentInputFormat: AVAudioFormat?
    private let wavFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!
    private var hasTap = false
    // Monitoramento de saúde do engine
    private var engineConfigObserver: NSObjectProtocol?
    private var engineHealthTimer: Timer?

    // Recording state
    private var audioFile: AVAudioFile?
    private var audioFilePath: String?

    // Dedicated URLSession for server communication (reused, no caching)
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    init() {
        appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ditado")
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
        killOrphanServer()
        launchServerProcess()
    }

    private func launchServerProcess() {
        guard serverProcess == nil || serverProcess?.isRunning == false else { return }
        serverReady = false

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

        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            self.serverReady = false
            if proc.terminationStatus != 0 && proc.terminationReason != .exit {
                Log.d("WhisperService: servidor crashou (status \(proc.terminationStatus)) — reiniciando...")
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    self.serverProcess = nil
                    self.launchServerProcess()
                }
            }
        }

        do {
            try process.run()
            serverProcess = process
            Log.d("WhisperService: servidor iniciado (PID \(process.processIdentifier), porta \(serverPort))")

            DispatchQueue.global().async { [weak self] in
                guard let self = self else { return }
                for _ in 0..<40 {
                    Thread.sleep(forTimeInterval: 0.5)
                    if self.pingServer() {
                        self.serverReady = true
                        Log.d("WhisperService: servidor pronto (modelo na GPU)")
                        return
                    }
                    guard self.serverProcess?.isRunning == true else {
                        Log.d("WhisperService: servidor morreu durante startup")
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
        guard let process = serverProcess else { return }
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        serverProcess = nil
        serverReady = false
        Log.d("WhisperService: servidor parado")
    }

    private func killOrphanServer() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "whisper-server.*--port \(serverPort)"]
        try? task.run()
        task.waitUntilExit()
    }

    private func pingServer() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        session.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return ok
    }

    private var useServer: Bool {
        serverReady && serverProcess?.isRunning == true
    }

    // MARK: - Engine persistente (sempre ativo)

    /// Inicia o engine de áudio persistente com tap silencioso.
    /// Chamado uma vez no startup — bloqueia a main thread por 200-2000ms
    /// para inicializar o hardware, mas elimina cold start em todas as ditações.
    func startEngine() {
        guard engine == nil else { return }

        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        persistentInputFormat = format

        // Instala tap silencioso para manter o hardware de áudio ativo
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in
            // Descarta todo o áudio — apenas mantém o hardware inicializado
        }
        hasTap = true

        do {
            try newEngine.start()
            engine = newEngine
            Log.d("WhisperService: engine persistente pronto — hardware inicializado (\(Int(format.sampleRate))Hz)")
        } catch {
            inputNode.removeTap(onBus: 0)
            hasTap = false
            Log.d("WhisperService: falha ao iniciar engine persistente: \(error)")
            return
        }

        // Observa mudanças de configuração de áudio (Bluetooth, fone, troca de device).
        // Quando o macOS para o engine por qualquer motivo, este handler reinicia tudo.
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: newEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }

        // Health check a cada 30s — detecta engine parado por inatividade do macOS.
        engineHealthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, let eng = self.engine else { return }
            guard !eng.isRunning, self.audioFile == nil else { return }
            Log.d("WhisperService: engine inativo (health check) — reiniciando...")
            self.handleEngineConfigurationChange()
        }
    }

    func stopEngine() {
        engineHealthTimer?.invalidate()
        engineHealthTimer = nil
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }
        guard let eng = engine else { return }
        if hasTap {
            eng.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        eng.stop()
        engine = nil
        Log.d("WhisperService: engine parado")
    }

    /// Chamado quando o macOS muda a configuração de áudio (device change, Bluetooth, sleep/wake).
    /// Reinstala o tap silencioso e reinicia o engine para manter o estado "sempre ativo".
    private func handleEngineConfigurationChange() {
        guard let eng = engine else { return }

        // Remove tap atual (pode estar inválido após a mudança de configuração)
        if hasTap {
            eng.inputNode.removeTap(onBus: 0)
            hasTap = false
        }

        // Se havia gravação em andamento, descarta (áudio corrompido pela interrupção)
        if audioFile != nil {
            Log.d("WhisperService: gravação interrompida por mudança de configuração")
            audioFile = nil
            if let path = audioFilePath {
                try? FileManager.default.removeItem(atPath: path)
            }
            audioFilePath = nil
        }

        // Atualiza formato (device pode ter mudado sample rate)
        let inputNode = eng.inputNode
        let newFormat = inputNode.outputFormat(forBus: 0)
        persistentInputFormat = newFormat

        // Reinstala tap silencioso e reinicia engine
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: newFormat) { _, _ in }
        hasTap = true

        do {
            try eng.start()
            Log.d("WhisperService: engine reiniciado após mudança de configuração (\(Int(newFormat.sampleRate))Hz)")
        } catch {
            inputNode.removeTap(onBus: 0)
            hasTap = false
            Log.d("WhisperService: falha ao reiniciar engine: \(error)")
        }
    }

    // MARK: - Recording

    /// Troca o tap silencioso pelo tap de gravação — operação instantânea
    /// pois o engine já está rodando. Sem cold start.
    func startRecording() -> Bool {
        guard let eng = engine, let inputFormat = persistentInputFormat else {
            Log.d("WhisperService: engine não disponível")
            return false
        }

        let tmpPath = NSTemporaryDirectory() + "ditado_\(Int(Date().timeIntervalSince1970)).wav"

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

        let inputNode = eng.inputNode

        // Remove tap silencioso e instala tap de gravação (swap instantâneo)
        if hasTap {
            inputNode.removeTap(onBus: 0)
            hasTap = false
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let file = self.audioFile else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.wavFormat, frameCapacity: frameCount) else { return }

            // FIX: flag consumed evita que o converter reuse o mesmo buffer,
            // o que causava corrupção de áudio e palavras perdidas.
            var consumed = false
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                guard !consumed else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let error = error {
                Log.d("WhisperService: erro converter: \(error.localizedDescription)")
            } else if convertedBuffer.frameLength > 0 {
                do {
                    try file.write(from: convertedBuffer)
                } catch {
                    Log.d("WhisperService: erro ao gravar buffer: \(error.localizedDescription)")
                }
            }
        }
        hasTap = true

        Log.d("WhisperService: gravando em \(tmpPath) (swap instantâneo ✓)")
        return true
    }

    // MARK: - Transcription

    func stopAndTranscribe(completion: @escaping (String?) -> Void) {
        let capturedPath = audioFilePath
        audioFilePath = nil

        // FIX última palavra: aguarda 200ms antes de parar de gravar,
        // capturando o final da última palavra pronunciada.
        DispatchQueue.global().asyncAfter(deadline: .now() + Config.trailingDelay) { [self] in
            // Operações de tap devem ocorrer na main thread (AVAudioEngine não é thread-safe)
            DispatchQueue.main.async { [self] in
                self.engine?.inputNode.removeTap(onBus: 0)
                self.hasTap = false
                self.audioFile = nil  // Fecha/flush o arquivo WAV

                // Reinstala tap silencioso — engine continua ativo para próxima ditação
                self.reinstallSilentTap()

                // Transcreve em background (operação lenta)
                DispatchQueue.global().async { [self] in
                    self.runTranscription(path: capturedPath, completion: completion)
                }
            }
        }
    }

    func cancel() {
        if hasTap {
            engine?.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        audioFile = nil
        if let path = audioFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        audioFilePath = nil
        reinstallSilentTap()
    }

    private func reinstallSilentTap() {
        guard let eng = engine, let format = persistentInputFormat, !hasTap else { return }

        // Se o engine foi parado pelo sistema, reinicia antes de instalar o tap
        if !eng.isRunning {
            Log.d("WhisperService: engine inativo ao reinstalar tap — reiniciando...")
            do {
                try eng.start()
            } catch {
                Log.d("WhisperService: falha ao reiniciar engine: \(error)")
                return
            }
        }

        eng.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
        hasTap = true
    }

    private func runTranscription(path: String?, completion: @escaping (String?) -> Void) {
        guard let path = path else {
            Log.d("WhisperService: sem arquivo de áudio")
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        Log.d("WhisperService: transcrevendo... WAV=\(fileSize) bytes (+\(Int(Config.trailingDelay * 1000))ms trailing)")

        if fileSize < 8000 {
            Log.d("WhisperService: arquivo muito pequeno (\(fileSize)b), ignorando")
            try? FileManager.default.removeItem(atPath: path)
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let start = CFAbsoluteTimeGetCurrent()

        let result: String?
        if useServer {
            result = transcribeViaServer(audioPath: path)
        } else {
            Log.d("WhisperService: servidor indisponível, usando CLI (mais lento)")
            result = transcribeViaCLI(audioPath: path)
        }

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

        let debugPath = NSTemporaryDirectory() + "ditado_last.wav"
        try? FileManager.default.removeItem(atPath: debugPath)
        try? FileManager.default.copyItem(atPath: path, toPath: debugPath)
        try? FileManager.default.removeItem(atPath: path)

        DispatchQueue.main.async {
            Log.d("WhisperService: resultado (\(elapsed)ms) = '\(result ?? "nil")'")
            completion(result)
        }
    }

    // MARK: - Server-based transcription (fast — model already in GPU)

    private func transcribeViaServer(audioPath: String) -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/inference") else { return nil }

        let fileURL = URL(fileURLWithPath: audioPath)
        guard let fileData = try? Data(contentsOf: fileURL) else { return nil }

        let boundary = "VoiceDict-\(UUID().uuidString)"
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("text\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("pt\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var result: String?

        session.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                Log.d("WhisperService [server]: erro HTTP: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.d("WhisperService [server]: HTTP \(http.statusCode)")
                return
            }
            guard let data = data, let text = String(data: data, encoding: .utf8) else { return }
            result = self.cleanWhisperOutput(text)
        }.resume()

        let waitResult = sem.wait(timeout: .now() + 15)
        if waitResult == .timedOut {
            Log.d("WhisperService [server]: timeout 15s — fallback CLI")
            return transcribeViaCLI(audioPath: audioPath)
        }
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
