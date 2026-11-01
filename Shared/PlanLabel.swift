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
        // Anthropic / Claude。2026年10月の改称で Max 5x → Max、Max 20x → Ultra になった。
        // 識別子は `default_claude_max_20x` のまま来るので、表示側で読み替える。
        "max": "Max",
        "max5x": "Max",
        "max20x": "Ultra",
        "ultra": "Ultra",
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

    /// 頭に付くことがある名前空間と修飾。落としてから対応表を引く。
    /// 例: `default_claude_max_20x` は `default` と `claude` を落として `max20x`。
    private static let prefixes = ["default", "claudeai", "claude", "anthropic", "chatgpt", "openai"]

    /// 制御文字などを落として前後を詰める。読めない値はnil。
    private static func sanitized(_ raw: String) -> String? {
        let safeScalars = raw.unicodeScalars.lazy.filter {
            switch $0.properties.generalCategory {
            case .control, .format, .surrogate: return false
            default: return true
            }
        }.prefix(256)
        return String(String.UnicodeScalarView(Array(safeScalars)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// 区切りと名前空間を落として対応表を引くための鍵にする。
    private static func lookupKey(for raw: String) -> String {
        var key = raw.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        // 重ねて付くことがあるので、落とせなくなるまで繰り返す。
        var strips = 0
        while strips < prefixes.count,
              let prefix = prefixes.first(where: { key.hasPrefix($0) && key != $0 }) {
            key.removeFirst(prefix.count)
            strips += 1
        }
        return key
    }

    /// 対応表に載っている場合だけ表示名を返す。推測した整形はしない。
    static func knownLabel(for raw: String, vendor: Vendor = .any) -> String? {
        guard let trimmed = sanitized(raw) else { return nil }
        let key = lookupKey(for: trimmed)
        if vendor == .openAI, let mapped = openAI[key] { return mapped }
        return known[key]
    }

    static func normalize(_ raw: String?, vendor: Vendor = .any) -> String? {
        guard let raw, let trimmed = sanitized(raw) else { return nil }
        if let mapped = knownLabel(for: trimmed, vendor: vendor) { return mapped }

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

extension PlanLabel {
    /// Claudeのプラン表記。倍率は `rateLimitTier`（例: `default_claude_max_20x`）にしか
    /// 入っておらず、`subscriptionType` は `max` としか言わない。
    ///
    /// 同じ等級のまま呼び名だけが変わることがある（2026年10月の Max 20x → Ultra）。
    /// Claude自身が記録している表示名（`~/.claude.json` の `planDisplayName`）が
    /// あればそれを最優先で採り、改称にこちらの対応表より先に追従する。
    /// 無ければ等級の対応表、それも知らない形なら従来どおりの表記に戻す。
    static func anthropicPlan(
        subscriptionType: String?,
        rateLimitTier: String?,
        displayName: String? = nil
    ) -> String? {
        if let displayName, let named = normalize(displayName) { return named }
        if let tier = rateLimitTier, let graded = knownLabel(for: tier) { return graded }
        return normalize(subscriptionType)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
