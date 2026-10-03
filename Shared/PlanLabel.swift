import Foundation

/// プラン名の表記ゆれを整える。
///
/// 各ツールが返すのは内部識別子（Codex の `prolite` など）だったり、
/// すでに表示用の名前（Grok の `X Premium+`）だったりする。
/// 対応表に無いものは推測せず、読める形に整えるだけに留める。
enum PlanLabel {
    /// 提供元によって同じ識別子が別のプランを指す。`pro` はClaudeでは「Pro」だが、
    /// OpenAIでは等級が分かれて「Pro 200」になる。引く表を提供元で分ける。
    enum Vendor {
        case any
        case openAI
    }

    private static let known: [String: String] = [
        "free": "Free",
        "plus": "Plus",
        "pro": "Pro",
        "team": "Team",
        "business": "Business",
        "enterprise": "Enterprise",
        "edu": "Edu",
        // Anthropic / Claude。倍率付きの識別子で来ることがあるが、等級は表に出さない。
        "max": "Max",
        "max5x": "Max",
        "max20x": "Max",
    ]

    /// OpenAI / Codex。識別子は `codex app-server` が返す `planType`。
    ///
    /// ProはPro 100 / Pro 200 / Pro 500へ分かれ、それぞれ `prolite` / `pro` / `promax` で来る。
    /// Businessには標準シートとプレミアムシートがあり、プレミアムシートは
    /// `self_serve_business_prolite`（Pro 100相当の枠）で来る。使える量が変わるので表に出す。
    /// 対応はChatGPTアプリ内の表示文言（`plan, select, … prolite {Pro 100} pro {Pro 200}
    /// promax {Pro 500}`、`teamPlanName` → Business）に合わせた。
    private static let openAI: [String: String] = [
        "go": "Go",
        "prolite": "Pro 100",
        "pro": "Pro 200",
        "promax": "Pro 500",
        "team": "Business",
        "selfservebusinessprolite": "Business Premium",
        "selfservebusinessusagebased": "Business Usage-based",
        "ent26": "Enterprise",
        "enterprisecbpautomation": "Enterprise",
        "enterprisecbpusagebased": "Enterprise",
        "education": "Edu",
        "eduplus": "Edu Plus",
        "edupro": "Edu Pro",
    ]

    /// 頭に付くことがある名前空間。落としてから対応表を引く。
    private static let prefixes = ["claudeai", "claude", "anthropic", "chatgpt", "openai"]

    static func normalize(_ raw: String?, vendor: Vendor = .any) -> String? {
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
        if vendor == .openAI, let mapped = openAI[key] { return mapped }
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
