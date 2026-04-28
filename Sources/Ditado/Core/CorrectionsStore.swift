import Foundation

struct CorrectionRule: Codable {
    let from: String
    let to: String
    let createdAt: Date
}

/// Persistente em ~/Library/Application Support/Ditado/corrections.json.
/// Aplica substituição word-boundary case-insensitive preservando o caso da ocorrência.
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
        let f = rawFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = rawTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty, f.lowercased() != t.lowercased() else { return }
        lock.lock(); defer { lock.unlock() }
        rules.removeAll { $0.from.lowercased() == f.lowercased() }
        rules.append(CorrectionRule(from: f, to: t, createdAt: Date()))
        save()
    }

    func remove(from rawFrom: String) {
        lock.lock(); defer { lock.unlock() }
        rules.removeAll { $0.from.lowercased() == rawFrom.lowercased() }
        save()
    }

    // MARK: - Application

    /// Aplica todas as regras ao texto. Word-boundary, case-insensitive,
    /// preserva caso da ocorrência (UPPER, Title, lower).
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
        let escaped = NSRegularExpression.escapedPattern(for: rule.from)
        // \b funciona razoavelmente para PT — palavras com acentos são tratadas como letra pelo NSRegex em modo Unicode.
        let pattern = "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            let replacement = preserveCase(target: rule.to, sample: matched)
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    private func preserveCase(target: String, sample: String) -> String {
        guard !sample.isEmpty else { return target }
        if sample.count > 1 && sample == sample.uppercased() {
            return target.uppercased()
        }
        if let first = sample.first, first.isUppercase {
            return target.prefix(1).uppercased() + target.dropFirst()
        }
        return target
    }
}
