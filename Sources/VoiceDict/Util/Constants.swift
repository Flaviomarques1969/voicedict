import Foundation

enum Config {
    // Timing
    static let activationDelay: TimeInterval = 0.180   // 180ms hold before recording
    static let processingTimeout: TimeInterval = 5.0    // Safety timeout for STT
    static let clipboardRestoreDelay: TimeInterval = 0.100 // Wait before restoring clipboard
    static let cooldownDuration: TimeInterval = 0.300   // Min gap between dictation sessions
    static let tapReEnableInterval: TimeInterval = 5.0  // Check event tap health

    // Device-specific modifier masks (from IOKit NX_ constants)
    // Hotkey: Left Shift + Left Control
    static let leftShiftMask: UInt64   = 0x00000002
    static let leftControlMask: UInt64 = 0x00000001
    static let rightShiftMask: UInt64  = 0x00000004
    static let rightControlMask: UInt64 = 0x00002000

    // Speech
    static let speechLocale = Locale(identifier: "pt-BR")

    // Log
    static let logFile = "/tmp/voicedict.log"
}

// MARK: - File logger (debug)

enum Log {
    private static let handle: FileHandle? = {
        FileManager.default.createFile(atPath: Config.logFile, contents: nil)
        return FileHandle(forWritingAtPath: Config.logFile)
    }()

    static func d(_ msg: String) {
        let line = "[VoiceDict \(timestamp())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            handle?.seekToEndOfFile()
            handle?.write(data)
        }
        // Also NSLog for system console
        NSLog("[VoiceDict] %@", msg)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
