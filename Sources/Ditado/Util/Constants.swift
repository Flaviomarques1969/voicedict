import Foundation

enum Config {
    // Timing
    static let activationDelay: TimeInterval = 0.080   // 80ms hold before recording (era 180ms — reduzido para capturar primeira palavra)
    static let processingTimeout: TimeInterval = 5.0    // Safety timeout for STT
    static let clipboardRestoreDelay: TimeInterval = 0.100 // Wait before restoring clipboard
    static let cooldownDuration: TimeInterval = 0.300   // Min gap between dictation sessions
    static let tapReEnableInterval: TimeInterval = 5.0  // Check event tap health
    static let trailingDelay: TimeInterval = 0.200      // 200ms trailing audio after hotkey release (captures last word)

    // Device-specific modifier masks (from IOKit NX_ constants)
    // Hotkey: Left Shift + Left Control
    static let leftShiftMask: UInt64   = 0x00000002
    static let leftControlMask: UInt64 = 0x00000001
    static let rightShiftMask: UInt64  = 0x00000004
    static let rightControlMask: UInt64 = 0x00002000

    // Speech
    static let speechLocale = Locale(identifier: "pt-BR")

    // Log
    static let logFile = "/tmp/ditado.log"
    static let logMaxSize = 512 * 1024 // 512KB — rotate if exceeded
    static let logKeepLines = 500      // Keep last N lines on rotation
}

// MARK: - File logger (debug)

enum Log {
    private static let handle: FileHandle? = {
        FileManager.default.createFile(atPath: Config.logFile, contents: nil)
        return FileHandle(forWritingAtPath: Config.logFile)
    }()

    // Cached DateFormatter — expensive to create, reuse across all log calls
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // NSLock garante que writes de múltiplas threads (main, global, timer) não colidam
    private static let writeLock = NSLock()
    private static var bytesWritten = 0

    static func d(_ msg: String) {
        let line = "[Ditado \(formatter.string(from: Date()))] \(msg)\n"
        NSLog("[Ditado] %@", msg)
        guard let data = line.data(using: .utf8) else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        handle?.seekToEndOfFile()
        handle?.write(data)
        bytesWritten += data.count

        // Rotate if log exceeds max size
        if bytesWritten > Config.logMaxSize {
            rotateLog()
        }
    }

    private static func rotateLog() {
        guard let data = FileManager.default.contents(atPath: Config.logFile),
              let content = String(data: data, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")
        let kept = lines.suffix(Config.logKeepLines).joined(separator: "\n")
        handle?.truncateFile(atOffset: 0)
        handle?.seek(toFileOffset: 0)
        if let keptData = kept.data(using: .utf8) {
            handle?.write(keptData)
            bytesWritten = keptData.count
        }
    }
}
