import Foundation

/// 一つの制限ウィンドウ（例: Claude の 5 時間枠 / 週枠、Codex の週枠）。
struct UsageWindow: Codable, Hashable, Identifiable {
    var id: String            // "five_hour" / "seven_day" / "primary" ...
    var label: String         // 画面表示用の短いラベル
    var usedPercent: Double   // 0...100
    var resetsAt: Date?
    /// 窓の長さ（秒）。5 時間枠かどうかの判定と、消費ペースの計算に使う。
    var windowSeconds: TimeInterval?

    init(id: String, label: String, usedPercent: Double, resetsAt: Date?,
         windowSeconds: TimeInterval?) {
        self.id = id
        self.label = label
        self.usedPercent = Self.validPercent(usedPercent)
        self.resetsAt = Self.validDate(resetsAt)
        self.windowSeconds = Self.validWindowSeconds(windowSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, usedPercent, resetsAt, windowSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)

        let rawPercent = try values.decode(Double.self, forKey: .usedPercent)
        guard rawPercent.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .usedPercent, in: values, debugDescription: "Usage percent must be finite"
            )
        }
        usedPercent = Self.validPercent(rawPercent)

        resetsAt = Self.validDate(try values.decodeIfPresent(Date.self, forKey: .resetsAt))
        windowSeconds = Self.validWindowSeconds(
            try values.decodeIfPresent(TimeInterval.self, forKey: .windowSeconds)
        )
    }

    private static func validPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    private static func validDate(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite,
              timestamp >= 946_684_800,
              timestamp <= 7_258_118_400
        else { return nil }
        return date
    }

    private static func validWindowSeconds(_ seconds: TimeInterval?) -> TimeInterval? {
        guard let seconds, seconds.isFinite, seconds > 0,
              seconds <= 10 * 365 * 86_400
        else { return nil }
        return seconds
    }

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    /// 短い窓ほど「いま効いてくる」制限。5 時間枠を優先表示するための判定。
    var isShortWindow: Bool {
        guard let windowSeconds else { return false }
        return windowSeconds <= 6 * 3_600
    }

    /// 今から date までを "2d 3h" / "42m" のように表す。
    static func durationText(until date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval.isFinite else { return "unknown" }
        guard interval <= 10 * 365 * 86_400 else { return "unknown" }
        if interval <= -60 { return "passed" }
        if interval < 60 { return "<1m" }
        let seconds = Int(interval.rounded(.down))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// リセットまでの残り時間。
    var resetsInText: String? {
        resetsAt.map { UsageWindow.durationText(until: $0) }
    }
}

enum AgentStatus: String, Codable {
    case ok            // 新しい実測値がある
    case stale         // 値はあるが古い
    case unavailable   // インストール済みだがデータ未取得
    case notInstalled  // そもそも入っていない
}

struct AgentUsage: Codable, Hashable, Identifiable {
    static let maximumStaleRetention: TimeInterval = 30 * 86_400
    var id: String            // "claude-code" / "codex" ...
    var name: String
    var plan: String?
    var windows: [UsageWindow]
    var observedAt: Date?
    var source: String        // データの出どころ（UI のツールチップ用）
    var status: AgentStatus
    var note: String?         // 未取得時に何をすれば良いかの案内

    /// 一番逼迫しているウィンドウ。メニューバーの要約に使う。
    var tightestWindow: UsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    /// このエージェントを代表する窓。5 時間枠のような短い窓を優先する。
    var headlineWindow: UsageWindow? {
        let short = windows.filter(\.isShortWindow)
        if let pick = short.max(by: { $0.usedPercent < $1.usedPercent }) { return pick }
        return tightestWindow
    }

    /// Collectorの状態と観測時刻を統合した表示用の鮮度。
    var displayStatus: AgentStatus {
        displayStatus(at: Date())
    }

    func displayStatus(at now: Date) -> AgentStatus {
        guard !windows.isEmpty else { return status }
        guard status == .ok else { return status }
        guard let observedAt else { return .stale }
        let age = now.timeIntervalSince(observedAt)
        guard age.isFinite else { return .stale }
        guard age >= -5 * 60 else { return .stale }
        return age > 6 * 3_600 ? .stale : .ok
    }

    /// A stale percentage stops being meaningful once its quota window has reset.
    /// Unknown reset dates get a bounded fallback so an abandoned local log cannot
    /// remain on screen forever.
    func expiringStaleData(at now: Date) -> AgentUsage {
        let observationIsStale = displayStatus(at: now) == .stale
        let age = observedAt.map { now.timeIntervalSince($0) }
        let retained = windows.filter { window in
            if let resetsAt = window.resetsAt { return resetsAt > now }
            guard observationIsStale else { return true }
            guard let age, age.isFinite else { return false }
            return age >= 0 && age <= Self.maximumStaleRetention
        }
        guard retained.count != windows.count else { return self }

        var copy = self
        copy.windows = retained
        if retained.isEmpty {
            copy.status = .unavailable
            copy.note = expiredDataNote
        }
        return copy
    }

    private var expiredDataNote: String {
        switch id {
        case "claude-code":
            return "Claude usage data expired; sign in to Claude Code again, then check again"
        case "codex":
            return "Codex usage data expired; complete a Codex response, then check again"
        case "grok":
            return "Grok usage data expired; use Grok, then check again"
        default:
            return "Stored usage data expired; use the agent, then check again"
        }
    }

}

struct UsageSnapshot: Codable, Hashable {
    var updatedAt: Date
    var agents: [AgentUsage]
    /// 利用者が優先表示に指定したエージェント。未指定なら自動判定。
    var preferredAgentID: String?

    static let empty = UsageSnapshot(updatedAt: .distantPast, agents: [])

    func expiringStaleData(at now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            updatedAt: updatedAt,
            agents: agents.map { $0.expiringStaleData(at: now) },
            preferredAgentID: preferredAgentID
        )
    }

    /// 見出しに出す 1 件。決め方は 3 段階。
    ///  1. 利用者が優先指定したエージェント
    ///  2. 5 時間枠のように短い窓（真っ先に効いてくるため）
    ///  3. 全体で最も逼迫している窓
    var headline: (agent: AgentUsage, window: UsageWindow)? {
        let actionable = agents.filter {
            ($0.displayStatus == .ok || $0.displayStatus == .stale) && !$0.windows.isEmpty
        }

        if let preferredAgentID,
           let pinned = actionable.first(where: { $0.id == preferredAgentID }),
           let window = pinned.headlineWindow {
            return (agent: pinned, window: window)
        }

        let current = actionable.filter { $0.displayStatus == .ok }
        if let pick = automaticHeadline(in: current) { return pick }
        return automaticHeadline(in: actionable.filter { $0.displayStatus == .stale })
    }

    private func automaticHeadline(
        in candidates: [AgentUsage]
    ) -> (agent: AgentUsage, window: UsageWindow)? {
        let shortWindows = candidates.flatMap { agent in
            agent.windows.filter(\.isShortWindow).map { (agent: agent, window: $0) }
        }
        if let pick = shortWindows.max(by: { $0.window.usedPercent < $1.window.usedPercent }) {
            return pick
        }

        let all = candidates.flatMap { agent in
            agent.windows.map { (agent: agent, window: $0) }
        }
        return all.max { $0.window.usedPercent < $1.window.usedPercent }
    }

    /// 見出しと同じエージェントの、見出し以外の窓（7d など）。
    var headlineSecondary: UsageWindow? {
        guard let headline else { return nil }
        return headline.agent.windows.first { $0.id != headline.window.id }
    }
}
