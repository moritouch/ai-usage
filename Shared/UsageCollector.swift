import Foundation

enum UsageCollector {
    static func collectAll(order: [String] = []) async -> UsageSnapshot {
        var agents = [
            await ClaudeCollector.collect(),
            CodexCollector.collect(),
            GrokCollector.collect(),
        ]

        // 利用者が並べ替えた順に整える。未登録のものは元の順で後ろに残す。
        if !order.isEmpty {
            agents = agents.enumerated().sorted { lhs, rhs in
                let l = order.firstIndex(of: lhs.element.id) ?? (order.count + lhs.offset)
                let r = order.firstIndex(of: rhs.element.id) ?? (order.count + rhs.offset)
                return l < r
            }.map(\.element)
        }

        // 自動順ではpinせず、短い窓→逼迫度の判定に任せる。
        // 利用者が並べ替えた時だけ、先頭の実データ持ちを見出しにする。
        let headliner = order.isEmpty ? nil : agents.first { !$0.windows.isEmpty }?.id

        return UsageSnapshot(updatedAt: Date(), agents: agents,
                             preferredAgentID: headliner)
    }

}
