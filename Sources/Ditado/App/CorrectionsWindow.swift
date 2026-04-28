import Cocoa

/// Janela de correção: mostra a última transcrição com cada palavra clicável.
/// Clicar abre prompt para informar a forma correta — gera regra persistente
/// em CorrectionsStore que será aplicada a todas as transcrições futuras.
final class CorrectionsWindow: NSObject, NSTextViewDelegate, NSWindowDelegate {

    static let shared = CorrectionsWindow()

    private var window: NSWindow?
    private var transcriptView: NSTextView?
    private var rulesStack: NSStackView?
    private var emptyTranscriptLabel: NSTextField?
    private var lastTranscription: String = ""

    func show(lastTranscription: String) {
        self.lastTranscription = lastTranscription
        if window == nil { build() }
        renderTranscription()
        renderRules()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Build

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Correções de transcrição"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let content = NSView()
        win.contentView = content

        let title1 = makeHeading("Última transcrição")
        let hint1 = makeHint("Clique em uma palavra para ensinar ao Ditado a forma correta.")

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.delegate = self
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true

        let title2 = makeHeading("Regras de correção")
        let hint2 = makeHint("Cada regra substitui a palavra escrita pelo Whisper pela forma correta — sempre.")

        let rules = NSStackView()
        rules.orientation = .vertical
        rules.alignment = .leading
        rules.spacing = 4

        let rulesScroll = NSScrollView()
        rulesScroll.hasVerticalScroller = true
        rulesScroll.borderType = .lineBorder
        rulesScroll.drawsBackground = true

        let rulesContainer = FlippedView()
        rulesContainer.translatesAutoresizingMaskIntoConstraints = false
        rules.translatesAutoresizingMaskIntoConstraints = false
        rulesContainer.addSubview(rules)
        NSLayoutConstraint.activate([
            rules.topAnchor.constraint(equalTo: rulesContainer.topAnchor, constant: 6),
            rules.leadingAnchor.constraint(equalTo: rulesContainer.leadingAnchor, constant: 6),
            rules.trailingAnchor.constraint(equalTo: rulesContainer.trailingAnchor, constant: -6),
            rules.bottomAnchor.constraint(lessThanOrEqualTo: rulesContainer.bottomAnchor, constant: -6),
        ])
        rulesScroll.documentView = rulesContainer

        for v in [title1, hint1, scroll, title2, hint2, rulesScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            title1.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            title1.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            title1.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            hint1.topAnchor.constraint(equalTo: title1.bottomAnchor, constant: 2),
            hint1.leadingAnchor.constraint(equalTo: title1.leadingAnchor),
            hint1.trailingAnchor.constraint(equalTo: title1.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: hint1.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.heightAnchor.constraint(equalToConstant: 90),

            title2.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 16),
            title2.leadingAnchor.constraint(equalTo: title1.leadingAnchor),

            hint2.topAnchor.constraint(equalTo: title2.bottomAnchor, constant: 2),
            hint2.leadingAnchor.constraint(equalTo: title1.leadingAnchor),
            hint2.trailingAnchor.constraint(equalTo: title1.trailingAnchor),

            rulesScroll.topAnchor.constraint(equalTo: hint2.bottomAnchor, constant: 6),
            rulesScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            rulesScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            rulesScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            rulesContainer.widthAnchor.constraint(equalTo: rulesScroll.widthAnchor),
        ])

        window = win
        transcriptView = tv
        rulesStack = rules
    }

    private func makeHeading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .boldSystemFont(ofSize: 13)
        return l
    }

    private func makeHint(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        return l
    }

    // MARK: - Render

    private func renderTranscription() {
        guard let tv = transcriptView else { return }
        let text = lastTranscription
        let storage = tv.textStorage

        if text.isEmpty {
            let empty = NSAttributedString(string: "Faça uma ditação primeiro — depois reabra esta janela.", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 13),
            ])
            storage?.setAttributedString(empty)
            return
        }

        let attr = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        attr.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: full)

        if let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}']+") {
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let r = match?.range else { return }
                let word = (text as NSString).substring(with: r)
                guard let url = Self.linkURL(for: word) else { return }
                attr.addAttribute(.link, value: url, range: r)
            }
        }
        storage?.setAttributedString(attr)
    }

    private func renderRules() {
        guard let stack = rulesStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let rules = CorrectionsStore.shared.rules
        if rules.isEmpty {
            let empty = NSTextField(labelWithString: "Nenhuma regra ainda.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(empty)
            return
        }

        for rule in rules.sorted(by: { $0.createdAt > $1.createdAt }) {
            stack.addArrangedSubview(makeRuleRow(rule))
        }
    }

    private func makeRuleRow(_ rule: CorrectionRule) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline

        let label = NSTextField(labelWithString: "\(rule.from)  →  \(rule.to)")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        let del = NSButton(title: "Remover", target: self, action: #selector(removeRule(_:)))
        del.bezelStyle = .rounded
        del.controlSize = .small
        del.identifier = NSUserInterfaceItemIdentifier(rule.from)

        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView()) // spacer
        row.addArrangedSubview(del)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func removeRule(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        CorrectionsStore.shared.remove(from: id)
        renderRules()
    }

    // MARK: - Click on word

    private static let linkScheme = "ditado-correct"

    private static func linkURL(for word: String) -> URL? {
        var c = URLComponents()
        c.scheme = linkScheme
        c.host = "word"
        c.queryItems = [URLQueryItem(name: "w", value: word)]
        return c.url
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let u = link as? URL { url = u }
        else if let s = link as? String { url = URL(string: s) }
        else { url = nil }
        guard let u = url, u.scheme == Self.linkScheme,
              let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
              let word = comps.queryItems?.first(where: { $0.name == "w" })?.value else {
            return true
        }
        promptCorrection(for: word)
        return true
    }

    private func promptCorrection(for word: String) {
        let alert = NSAlert()
        alert.messageText = "Corrigir “\(word)”"
        alert.informativeText = "O Whisper escreveu “\(word)”. Qual é a palavra correta?\n\nA partir de agora, sempre que o Whisper escrever “\(word)”, será substituído automaticamente."
        alert.addButton(withTitle: "Salvar")
        alert.addButton(withTitle: "Cancelar")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "palavra correta"
        field.stringValue = ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let to = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, to.lowercased() != word.lowercased() else { return }

        CorrectionsStore.shared.add(from: word, to: to)
        // Aplica de volta na transcrição mostrada para feedback imediato
        lastTranscription = CorrectionsStore.shared.apply(lastTranscription)
        renderTranscription()
        renderRules()
    }
}

/// NSScrollView precisa de documentView "flipped" para que conteúdo cresça de cima para baixo.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
