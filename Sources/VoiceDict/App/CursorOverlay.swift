import Cocoa

/// Small floating indicator near the cursor during listening/processing states.
class CursorOverlay {

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var mouseTimer: Timer?

    private let panelSize: CGFloat = 28
    private let cursorOffset = NSPoint(x: 18, y: -18)

    func show(for state: DictationState) {
        if panel == nil { createPanel() }
        updateIcon(for: state)
        panel?.orderFront(nil)
        startTracking()
    }

    func hide() {
        stopTracking()
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let frame = NSRect(x: 0, y: 0, width: panelSize, height: panelSize)
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let iv = NSImageView(frame: frame)
        iv.imageScaling = .scaleProportionallyUpOrDown
        p.contentView = iv

        panel = p
        imageView = iv
        moveToMouse()
    }

    func updateIcon(for state: DictationState) {
        let symbolName: String
        let tint: NSColor

        switch state {
        case .listening:
            symbolName = "mic.fill"
            tint = .systemRed
        case .processing:
            symbolName = "ellipsis.circle"
            tint = .systemOrange
        default:
            hide()
            return
        }

        if let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
            let img = base.withSymbolConfiguration(config) ?? base
            let colored = img.copy() as! NSImage
            colored.lockFocus()
            tint.set()
            NSRect(origin: .zero, size: colored.size).fill(using: .sourceAtop)
            colored.unlockFocus()
            imageView?.image = colored
        }
    }

    private func startTracking() {
        stopTracking()
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.moveToMouse()
        }
    }

    private func stopTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
    }

    private func moveToMouse() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        // Position: right-below cursor, flipped if near screen edges
        var x = mouse.x + cursorOffset.x
        var y = mouse.y + cursorOffset.y - panelSize

        // Keep on screen
        let screenFrame = screen.visibleFrame
        if x + panelSize > screenFrame.maxX { x = mouse.x - cursorOffset.x - panelSize }
        if y < screenFrame.minY { y = mouse.y - cursorOffset.y }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
