import Cocoa

// MARK: - Events reported to the state machine

enum HotkeyEvent {
    case bothModifiersPressed
    case modifierReleased
    case nonModifierKeyDown
    case additionalModifierDetected
}

// MARK: - Global keyboard monitor via CGEvent tap

class HotkeyMonitor: NSObject {

    var onEvent: ((HotkeyEvent) -> Void)?
    var isActivating = false

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var reEnableTimer: Timer?

    // Debug: count events to confirm callback fires
    fileprivate var eventCount = 0

    func start() {
        tryCreateEventTap()

        reEnableTimer = Timer.scheduledTimer(withTimeInterval: Config.tapReEnableInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let tap = self.eventTap {
                if !CGEvent.tapIsEnabled(tap: tap) {
                    // Tap was disabled by macOS — destroy and recreate
                    // (a tap created before AX permission is "poisoned")
                    Log.d("Tap desabilitado — destruindo e recriando (AX: \(AXIsProcessTrusted()))")
                    self.destroyEventTap()
                    self.tryCreateEventTap()
                }
            } else {
                self.tryCreateEventTap()
            }
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    private func tryCreateEventTap() {
        guard eventTap == nil else { return }

        Log.d("Tentando criar event tap... (AX trusted: \(AXIsProcessTrusted()))")

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: selfPtr
        ) else {
            Log.d("FALHA ao criar event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.d("Event tap CRIADO com sucesso!")
    }

    func stop() {
        reEnableTimer?.invalidate()
        reEnableTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        destroyEventTap()
    }

    private func destroyEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    @objc private func handleWake() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.start()
        }
    }
}

// MARK: - C callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = monitor.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .flagsChanged {
        let raw = event.flags.rawValue

        // Log all modifier events with human-readable names
        var keys: [String] = []
        if raw & 0x00000001 != 0 { keys.append("L-CTRL") }
        if raw & 0x00002000 != 0 { keys.append("R-CTRL") }
        if raw & 0x00000002 != 0 { keys.append("L-SHIFT") }
        if raw & 0x00000004 != 0 { keys.append("R-SHIFT") }
        if raw & 0x00000008 != 0 { keys.append("L-CMD") }
        if raw & 0x00000010 != 0 { keys.append("R-CMD") }
        if raw & 0x00000020 != 0 { keys.append("L-OPT") }
        if raw & 0x00000040 != 0 { keys.append("R-OPT") }
        let desc = keys.isEmpty ? "(solto)" : keys.joined(separator: " + ")
        Log.d("🔑 \(desc)")

        let leftShift    = (raw & Config.leftShiftMask) != 0
        let leftControl  = (raw & Config.leftControlMask) != 0
        let rightShift   = (raw & Config.rightShiftMask) != 0
        let rightControl = (raw & Config.rightControlMask) != 0
        let anyCommand   = event.flags.contains(.maskCommand)
        let anyOption    = event.flags.contains(.maskAlternate)
        let extraModifiers = rightShift || rightControl || anyCommand || anyOption

        if leftShift && leftControl && !extraModifiers {
            Log.d(">>> L-Shift + L-Ctrl DETECTADO")
            monitor.onEvent?(.bothModifiersPressed)
        } else if !leftShift || !leftControl {
            monitor.onEvent?(.modifierReleased)
        } else {
            monitor.onEvent?(.additionalModifierDetected)
        }
    } else if type == .keyDown && monitor.isActivating {
        monitor.onEvent?(.nonModifierKeyDown)
    }

    return Unmanaged.passUnretained(event)
}
