import Cocoa

class TextInserter {

    // MARK: - Public API

    /// Insert text at the current cursor position via clipboard-swap + Cmd+V.
    func insert(_ text: String) {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard (all types)
        let savedItems = saveClipboard(pasteboard)

        // 2. Set transcribed text as clipboard content
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        // 3. Simulate Cmd+V
        simulatePaste()

        // 4. P6: wait, then restore original clipboard if nobody else touched it
        DispatchQueue.main.asyncAfter(deadline: .now() + Config.clipboardRestoreDelay) { [weak self] in
            if pasteboard.changeCount == changeCountAfterWrite {
                self?.restoreClipboard(pasteboard, items: savedItems)
            }
        }
    }

    /// Error fallback: leave text on clipboard and notify the user.
    func copyToClipboardAsFallback(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Beep + print — lightweight notification without UNUserNotificationCenter
        NSSound.beep()
        print("[VoiceDict] Texto copiado para clipboard (cole com Cmd+V): \(text.prefix(80))")
    }

    // MARK: - Clipboard save/restore

    private func saveClipboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        for item in items {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            saved.append(entry)
        }
        return saved
    }

    private func restoreClipboard(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        for entry in items {
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    // MARK: - Simulate Cmd+V

    private func simulatePaste() {
        let vKey: CGKeyCode = 9

        let down = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)
    }
}
