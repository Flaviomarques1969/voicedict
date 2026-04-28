import Cocoa

class StatusBarController: NSObject {

    private var statusItem: NSStatusItem?
    private let cursorOverlay = CursorOverlay()
    private var lastTranscription: String = ""

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(for: .idle)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Ditado v1.0", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Idioma: pt-BR", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hotkey: Left Shift + Left Control", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let correctItem = NSMenuItem(
            title: "Corrigir última transcrição…",
            action: #selector(openCorrections),
            keyEquivalent: "c"
        )
        correctItem.keyEquivalentModifierMask = [.command, .shift]
        correctItem.target = self
        menu.addItem(correctItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    func setLastTranscription(_ text: String) {
        lastTranscription = text
    }

    @objc private func openCorrections() {
        CorrectionsWindow.shared.show(lastTranscription: lastTranscription)
    }

    func updateIcon(for state: DictationState) {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        switch state {
        case .idle:       symbolName = "mic"
        case .activating: symbolName = "mic.badge.plus"
        case .listening:  symbolName = "mic.fill"
        case .processing: symbolName = "ellipsis.circle"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoiceDict \(state)") {
            image.isTemplate = true
            button.image = image
        }

        // Floating cursor indicator
        switch state {
        case .listening, .processing:
            cursorOverlay.show(for: state)
        default:
            cursorOverlay.hide()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
