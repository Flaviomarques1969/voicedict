import Cocoa

/// Small floating indicator near the cursor during listening/processing states.
class CursorOverlay {

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var mouseTimer: Timer?
    private var lastMousePos: NSPoint = .zero
    private var currentState: DictationState = .idle

    private let panelSize: CGFloat = 28
    private let cursorOffset = NSPoint(x: 18, y: -18)

    // Cached images — created once, reused
    private static let listeningImage: NSImage? = makeIcon("mic.fill", tint: .systemRed)
    private static let processingImage: NSImage? = makeIcon("ellipsis.circle", tint: .systemOrange)

    func show(for state: DictationState) {
        guard state == .listening || state == .processing else { hide(); return }
        if panel == nil { createPanel() }
        if currentState != state {
            currentState = state
            imageView?.image = state == .listening ? Self.listeningImage : Self.processingImage
        }
        panel?.orderFront(nil)
        startTracking()
    }

    func hide() {
        stopTracking()
        panel?.orderOut(nil)
        currentState = .idle
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

    private static func makeIcon(_ symbolName: String, tint: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        let img = base.withSymbolConfiguration(config) ?? base
        let colored = img.copy() as! NSImage
        colored.lockFocus()
        tint.set()
        NSRect(origin: .zero, size: colored.size).fill(using: .sourceAtop)
        colored.unlockFocus()
        return colored
    }

    private func startTracking() {
        guard mouseTimer == nil else { return }
        // 30 FPS is plenty for cursor tracking (vs 60 FPS before)
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.moveToMouseIfNeeded()
        }
    }

    private func stopTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
    }

    private func moveToMouseIfNeeded() {
        let mouse = NSEvent.mouseLocation
        // Skip if mouse hasn't moved (avoid needless layout)
        guard abs(mouse.x - lastMousePos.x) > 1 || abs(mouse.y - lastMousePos.y) > 1 else { return }
        lastMousePos = mouse
        moveToMouse()
    }

    private func moveToMouse() {
        guard let panel = panel else { return }
        let mouse = NSEvent.mouseLocation
        lastMousePos = mouse

        var x = mouse.x + cursorOffset.x
        var y = mouse.y + cursorOffset.y - panelSize

        // Keep on screen (check all edges)
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            if x + panelSize > sf.maxX { x = mouse.x - cursorOffset.x - panelSize }
            if x < sf.minX { x = sf.minX }
            if y < sf.minY { y = mouse.y - cursorOffset.y }
            if y + panelSize > sf.maxY { y = sf.maxY - panelSize }
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
