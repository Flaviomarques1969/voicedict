import AVFoundation

class AudioRecorder {

    private var audioEngine: AVAudioEngine?

    /// Start capturing audio. Returns false if audio can't be initialized.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // Validate input format
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.d("AudioRecorder: formato inválido (rate=\(format.sampleRate), ch=\(format.channelCount))")
            return false
        }

        Log.d("AudioRecorder: format=\(format.sampleRate)Hz, \(format.channelCount)ch")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onBuffer(buffer)
        }

        do {
            try engine.start()
            audioEngine = engine
            Log.d("AudioRecorder: gravando")
            return true
        } catch {
            Log.d("AudioRecorder: falha ao iniciar: \(error)")
            inputNode.removeTap(onBus: 0)
            return false
        }
    }

    func stop() {
        guard let engine = audioEngine else { return }
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
    }

    func cancel() {
        audioEngine = nil
    }
}
