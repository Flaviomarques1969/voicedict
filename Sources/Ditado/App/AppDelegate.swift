import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?
    private var stateMachine: StateMachine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.d("Iniciando...")
        Log.d("Accessibility: \(Permissions.checkAccessibility())")

        statusBarController = StatusBarController()
        statusBarController?.setup()

        if !Permissions.checkAccessibility() {
            Permissions.requestAccessibility()
            let alert = NSAlert()
            alert.messageText = "Permissão de Acessibilidade necessária"
            alert.informativeText = "Habilite Ditado em Configurações → Privacidade → Acessibilidade."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        // Request microphone then start
        Permissions.requestMicrophone { micGranted in
            Log.d("Microfone: \(micGranted)")
            DispatchQueue.main.async { [weak self] in
                self?.startStateMachine()
            }
        }
    }

    private func startStateMachine() {
        stateMachine = StateMachine()
        stateMachine?.onStateChanged = { [weak self] state in
            self?.statusBarController?.updateIcon(for: state)
        }
        stateMachine?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateMachine?.stop()
    }
}
