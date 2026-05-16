import Foundation

struct CorrectionRule: Codable {
    let from: String
    let to: String
    let createdAt: Date
}

/// Persistente em ~/Library/Application Support/Ditado/corrections.json.
/// Aplica substituição word-boundary, case-insensitive, accent-insensitive,
/// preservando o caso da ocorrência. Suporta `from` com várias palavras.
final class CorrectionsStore {

    static let shared = CorrectionsStore()

    private(set) var rules: [CorrectionRule] = []
    private let url: URL
    private let lock = NSLock()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ditado")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("corrections.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([CorrectionRule].self, from: data) {
            rules = decoded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(rules) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Mutations

    func add(from rawFrom: String, to rawTo: String) {
        let f = normalizeWhitespace(rawFrom)
        let t = normalizeWhitespace(rawTo)
        guard !f.isEmpty, !t.isEmpty,
              foldKey(f) != foldKey(t) else { return }
        lock.lock(); defer { lock.unlock() }
        rules.removeAll { foldKey($0.from) == foldKey(f) }
        rules.append(CorrectionRule(from: f, to: t, createdAt: Date()))
        save()
    }

    func remove(from rawFrom: String) {
        let f = normalizeWhitespace(rawFrom)
        lock.lock(); defer { lock.unlock() }
        rules.removeAll { foldKey($0.from) == foldKey(f) }
        save()
    }

    /// Vocabulário a ser passado como `initial_prompt` ao Whisper.
    /// Lista os destinos das regras (palavras corretas) — biases o modelo
    /// a transcrever essas palavras direto, em vez de inventar variações.
    /// Truncado em ~200 chars para não estourar o limite de tokens.
    func whisperPromptHint() -> String {
        lock.lock()
        let snapshot = rules
        lock.unlock()

        var seen = Set<String>()
        var words: [String] = []
        for r in snapshot {
            let key = r.to.lowercased()
            if seen.insert(key).inserted { words.append(r.to) }
        }
        guard !words.isEmpty else { return "" }

        var out = ""
        for w in words {
            let next = out.isEmpty ? w : out + ", " + w
            if next.count > 200 { break }
            out = next
        }
        return out
    }

    // MARK: - Application

    /// Aplica todas as regras ao texto. Word-boundary, case-insensitive,
    /// accent-insensitive, preserva caso da ocorrência (UPPER, Title, lower).
    func apply(_ text: String) -> String {
        lock.lock()
        let snapshot = rules
        lock.unlock()
        guard !snapshot.isEmpty else { return text }

        var result = text
        for rule in snapshot {
            result = applyRule(rule, to: result)
        }
        return result
    }

    private func applyRule(_ rule: CorrectionRule, to text: String) -> String {
        let foldedFrom = foldKey(rule.from)
        guard !foldedFrom.isEmpty else { return text }

        var result = text
        var searchStart = result.startIndex
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        while searchStart < result.endIndex,
              let range = result.range(of: rule.from, options: options, range: searchStart..<result.endIndex) {
            let prevOK = range.lowerBound == result.startIndex
                || !isWordChar(result[result.index(before: range.lowerBound)])
            let nextOK = range.upperBound == result.endIndex
                || !isWordChar(result[range.upperBound])

            if prevOK && nextOK {
                let matched = String(result[range])
                let replacement = preserveCase(target: rule.to, sample: matched)
                result.replaceSubrange(range, with: replacement)
                if let advanced = result.index(range.lowerBound, offsetBy: replacement.count, limitedBy: result.endIndex) {
                    searchStart = advanced
                } else {
                    break
                }
            } else {
                searchStart = result.index(after: range.lowerBound)
            }
        }
        return result
    }

    private func isWordChar(_ c: Character) -> Bool {
        return c.isLetter || c.isNumber || c == "_"
    }

    private func preserveCase(target: String, sample: String) -> String {
        // Se o target tem case mista própria (ex: "NFe", "macOS", "iPhone"), respeita-o
        // como forma canônica em vez de derivar caso da amostra.
        let targetLetters = target.filter { $0.isLetter }
        let hasUpper = targetLetters.contains(where: { $0.isUppercase })
        let hasLower = targetLetters.contains(where: { $0.isLowercase })
        if hasUpper && hasLower {
            return target
        }

        // Para amostras multi-palavra, considera só a primeira letra "alfabética".
        guard let firstLetter = sample.first(where: { $0.isLetter }) else { return target }
        let lettersOnly = sample.filter { $0.isLetter }
        if lettersOnly.count > 1 && lettersOnly == lettersOnly.uppercased() {
            return target.uppercased()
        }
        if firstLetter.isUppercase {
            return target.prefix(1).uppercased() + target.dropFirst()
        }
        return target
    }

    private func normalizeWhitespace(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func foldKey(_ s: String) -> String {
        return normalizeWhitespace(s)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
