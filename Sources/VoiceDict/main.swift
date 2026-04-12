import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

// withExtendedLifetime prevents ARC from deallocating delegate
// (NSApplication.delegate is weak, so the local var is the only strong ref)
withExtendedLifetime(delegate) {
    app.run()
}
