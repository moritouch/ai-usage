import Foundation

/// Cursor の残量。
///
/// Grok Bot と同じ cursor.com のアカウントで動くため、ログインは共有される。
/// 内訳（Auto / API）も応答に入っているが、画面の案内が総量を使っているので
/// こちらも総量だけを出す。
enum CursorCollector {
    struct Usage: Decodable, Sendable {
        struct Plan: Decodable, Sendable {
            let totalPercentUsed: Double?
        }
        let planUsage: Plan?
        let billingCycleStart: String?
        let billingCycleEnd: String?
    }

    static func collect() async -> AgentUsage {
        guard installed else {
            return AgentUsage(id: "cursor", name: "Cursor", plan: nil, windows: [],
                              observedAt: nil, source: "usage API",
                              status: .notInstalled, note: nil)
        }
        guard let cookie = CursorSession.load() else {
            return AgentUsage(
                id: "cursor", name: "Cursor", plan: nil, windows: [],
                observedAt: nil, source: "usage API", status: .unavailable,
                note: "Sign in to your Cursor account in Settings to read its usage"
            )
        }

        switch await CursorAPI.post("get-current-period-usage", cookie: cookie) {
        case let .body(data):
            guard let usage = try? JSONDecoder().decode(Usage.self, from: data) else {
                return unavailable(note: "Cursor usage could not be reached")
            }
            return agent(from: usage)
        case .unauthorized:
            return unavailable(
                note: "The saved Cursor sign-in was rejected; sign in again in Settings"
            )
        case .unavailable:
            return unavailable(note: "Cursor usage could not be reached")
        }
    }

    /// `~/.cursor` があるかどうかで判断する。入れていない人に設定を出しても仕方がない。
    static var installed: Bool {
        FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.cursor")
            || FileManager.default.fileExists(atPath: "/Applications/Cursor.app")
    }

    static func agent(from usage: Usage) -> AgentUsage {
        guard let used = usage.planUsage?.totalPercentUsed,
              used.isFinite, (0...100).contains(used)
        else { return unavailable(note: "Cursor usage could not be reached") }

        let start = CursorAPI.parseEpochMilliseconds(usage.billingCycleStart)
        let end = CursorAPI.parseEpochMilliseconds(usage.billingCycleEnd)
        let seconds = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : nil

        // 請求期間は月ごとで長さが揃わない。長さから見出しを作らず期間として扱う。
        let window = UsageWindow(
            id: "cursor_period",
            label: "Period",
            usedPercent: used,
            resetsAt: end,
            windowSeconds: (seconds.map { $0 > 0 } == true) ? seconds : nil
        )

        return AgentUsage(
            id: "cursor", name: "Cursor", plan: nil, windows: [window],
            observedAt: Date(), source: "usage API", status: .ok, note: nil
        )
    }

    private static func unavailable(note: String) -> AgentUsage {
        AgentUsage(id: "cursor", name: "Cursor", plan: nil, windows: [],
                   observedAt: nil, source: "usage API", status: .unavailable, note: note)
    }
}
