import Foundation

/// プラン名の表記ゆれを整える。
///
/// 各ツールが返すのは内部識別子（Codex の `prolite` など）だったり、
/// すでに表示用の名前（Grok の `X Premium+`）だったりする。
/// 対応表に無いものは推測せず、読める形に整えるだけに留める。
enum PlanLabel {
    private static let known: [String: String] = [
        // OpenAI / Codex
        "free": "Free",
        "plus": "Plus",
        "pro": "Pro",
        "prolite": "Pro",   // 内部識別子。等級までは表に出さない
        "team": "Team",
        "business": "Business",
        "enterprise": "Enterprise",
        "edu": "Edu",
        // Anthropic / Claude。倍率付きの識別子で来ることがあるが、等級は表に出さない。
        "max": "Max",
        "max5x": "Max",
        "max20x": "Max",
    ]

    /// 頭に付くことがある名前空間。落としてから対応表を引く。
    private static let prefixes = ["claudeai", "claude", "anthropic", "chatgpt", "openai"]

    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let safeScalars = raw.unicodeScalars.lazy.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .surrogate: return false
            default: return true
            }
        }.prefix(256)
        guard let trimmed = String(String.UnicodeScalarView(Array(safeScalars)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else { return nil }

        var key = trimmed.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        for prefix in prefixes where key.hasPrefix(prefix) && key != prefix {
            key.removeFirst(prefix.count)
            break
        }
        if let mapped = known[key] { return mapped }

        // すでに表示用の名前（空白や大文字を含む）ならそのまま活かす。
        if trimmed.contains(" ") || trimmed.rangeOfCharacter(from: .uppercaseLetters) != nil {
            return String(trimmed.prefix(128))
        }
        // 未知の識別子は区切りで割って語ごとに整える。max_20x -> Max 20x
        return String(trimmed
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map(\.capitalized)
            .joined(separator: " ")
            .prefix(128))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
