import Foundation

/// Grok Bot の残量。
///
/// Grok Bot は使用量をローカルへ書き残さないため、cursor.com の
/// `get-sand-usage-status`（`sand` は Grok Bot の内部名）へ問い合わせる。
/// 認証は利用者がアプリ内でログインして預けた Cookie を使う。
/// 既存の Grok（CLI）とは別枠で、Grok Bot 自身の画面も「別です」と明記している。
enum GrokBotCollector {

    struct Status: Decodable, Sendable {
        let usagePercent: Double?
        let currentPeriodStart: String?
        let nextResetTimestampUtc: String?
        let grokPlanLabel: String?
        let hasNonZeroIncludedLimit: Bool?
    }

    enum Outcome: Sendable {
        case status(Status)
        case unauthorized
        case unavailable
    }

    static func collect() async -> AgentUsage {
        guard let cookie = CursorSession.load() else {
            return AgentUsage(
                id: "grok-bot", name: "Grok Bot", plan: nil, windows: [],
                observedAt: nil, source: "usage API",
                status: installed ? .unavailable : .notInstalled,
                note: installed ? "Sign in to Grok Bot in Settings to read its usage" : nil
            )
        }

        switch await fetch(cookie: cookie) {
        case let .status(status):
            return agent(from: status)
        case .unauthorized:
            return AgentUsage(
                id: "grok-bot", name: "Grok Bot", plan: nil, windows: [],
                observedAt: nil, source: "usage API", status: .unavailable,
                note: "The saved Grok Bot sign-in was rejected; sign in again in Settings"
            )
        case .unavailable:
            return AgentUsage(
                id: "grok-bot", name: "Grok Bot", plan: nil, windows: [],
                observedAt: nil, source: "usage API", status: .unavailable,
                note: "Grok Bot usage could not be reached"
            )
        }
    }

    /// ログインが成立したかを応答で確かめる。Cookie名を決め打ちしないための判定。
    static func sessionWorks(cookie: String) async -> Bool {
        if case .status = await fetch(cookie: cookie) { return true }
        return false
    }

    /// アプリが入っていない環境では、設定に案内を出す意味がない。
    static var installed: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Grok Bot.app")
            || FileManager.default.fileExists(
                atPath: "\(NSHomeDirectory())/.grokbot"
            )
    }

    static func agent(from status: Status) -> AgentUsage {
        guard let used = status.usagePercent, used.isFinite, (0...100).contains(used),
              status.hasNonZeroIncludedLimit != false
        else {
            return AgentUsage(
                id: "grok-bot", name: "Grok Bot",
                plan: PlanLabel.normalize(status.grokPlanLabel), windows: [],
                observedAt: nil, source: "usage API", status: .unavailable,
                note: "Grok Bot usage could not be reached"
            )
        }

        let start = status.currentPeriodStart.flatMap(CursorAPI.parseISO8601)
        let reset = status.nextResetTimestampUtc.flatMap(CursorAPI.parseISO8601)
        let seconds = (start != nil && reset != nil)
            ? reset!.timeIntervalSince(start!)
            : nil

        // 期間の長さは一定ではない（観測では約3.5日）。長さから見出しを作ると
        // 実態と合わない数字を出してしまうので、既存のGrokと同じく期間として扱う。
        let window = UsageWindow(
            id: "grokbot_period",
            label: "Period",
            usedPercent: used,
            resetsAt: reset,
            windowSeconds: (seconds.map { $0 > 0 } == true) ? seconds : nil
        )

        return AgentUsage(
            id: "grok-bot", name: "Grok Bot",
            plan: PlanLabel.normalize(status.grokPlanLabel),
            windows: [window], observedAt: Date(),
            source: "usage API", status: .ok, note: nil
        )
    }

    private static func fetch(cookie: String) async -> Outcome {
        switch await CursorAPI.post("get-sand-usage-status", cookie: cookie) {
        case let .body(data):
            guard let status = try? JSONDecoder().decode(Status.self, from: data)
            else { return .unavailable }
            return .status(status)
        case .unauthorized:
            return .unauthorized
        case .unavailable:
            return .unavailable
        }
    }
}
