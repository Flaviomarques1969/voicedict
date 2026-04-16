import Cocoa

/// Small floating indicator near the text caret during listening/processing states.
class CursorOverlay {

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var trackingTimer: Timer?
    private var lastPos: NSPoint = .zero
    private var currentState: DictationState = .idle

    private let panelSize: CGFloat = 28
    private let caretOffset = NSPoint(x: 4, y: 4)

    // Cached images — modern SF Symbol coloring
    private static let listeningImage: NSImage? = makeIcon("ear.fill", tint: .systemTeal)
    private static let processingImage: NSImage? = makeIcon("ellipsis.circle", tint: .systemOrange)

    func show(for state: DictationState) {
        guard state == .listening || state == .processing else { hide(); return }
        if panel == nil { createPanel() }
        if currentState != state {
            currentState = state
            imageView?.image = state == .listening ? Self.listeningImage : Self.processingImage
            imageView?.contentTintColor = state == .listening ? .systemTeal : .systemOrange
        }
        panel?.orderFront(nil)
        positionAtCaret()
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
    }

    private static func makeIcon(_ symbolName: String, tint: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: tint)
        let combined = sizeConfig.applying(colorConfig)
        let img = base.withSymbolConfiguration(combined) ?? base
        img.isTemplate = false
        return img
    }

    // MARK: - Tracking

    private func startTracking() {
        guard trackingTimer == nil else { return }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.positionAtCaret()
        }
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    // MARK: - Positioning at text caret

    private func positionAtCaret() {
        guard let panel = panel else { return }
        let pos = textCaretPosition() ?? NSEvent.mouseLocation
        guard abs(pos.x - lastPos.x) > 1 || abs(pos.y - lastPos.y) > 1 else { return }
        lastPos = pos

        var x = pos.x + caretOffset.x
        var y = pos.y - panelSize - caretOffset.y

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            if x + panelSize > sf.maxX { x = pos.x - caretOffset.x - panelSize }
            if x < sf.minX { x = sf.minX }
            if y < sf.minY { y = pos.y + caretOffset.y }
            if y + panelSize > sf.maxY { y = sf.maxY - panelSize }
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Get text insertion caret position via Accessibility API.
    /// Falls back to nil if the focused element doesn't expose text attributes.
    private func textCaretPosition() -> NSPoint? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }

        let element = focused as! AXUIElement

        // Get selected text range (insertion point when length == 0)
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let range = rangeRef else { return nil }

        // Get screen bounds for that range
        var boundsRef: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            range,
            &boundsRef
        ) == .success, let boundsVal = boundsRef else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsVal as! AXValue, .cgRect, &rect) else { return nil }

        // AX uses top-left origin — convert to Cocoa bottom-left origin
        let primaryHeight = NSScreen.screens[0].frame.height
        let cocoaY = primaryHeight - rect.origin.y - rect.height
        return NSPoint(x: rect.origin.x + rect.width, y: cocoaY)
    }
}
