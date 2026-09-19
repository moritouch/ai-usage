import AppIntents
import WidgetKit

/// ウィジェットの「ウィジェットを編集」から選ぶエージェント。
struct AgentEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// 候補は本体が書き出した snapshot から拾う。未インストールのものは出さない。
struct AgentQuery: EntityQuery {
    func entities(for identifiers: [AgentEntity.ID]) async throws -> [AgentEntity] {
        available().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        available()
    }

    func defaultResult() async -> AgentEntity? {
        available().first
    }

    private func available() -> [AgentEntity] {
        SnapshotStore.load().agents
            .filter { $0.displayStatus != .notInstalled }
            .map { AgentEntity(id: $0.id, name: $0.name) }
    }
}

struct SelectAgentsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "AI Usage"
    static let description = IntentDescription(
        "Choose which agents to show, in order. Small widgets show one, medium widgets up to four quota rows, and large widgets up to five agents. One agent may use more than one row."
    )

    /// 選べる数を描ける数に揃える。小サイズは1つしか描かないので、2つ目以降は選べても映らない。
    /// 中・大の値は `UsageWidgetContent.capacity(for:)` のエージェント数と一致させる。
    /// 整数だけを書くと「ちょうどその数」になり、選び切るまで設定できなくなる。上限として書く。
    /// メタデータはビルド時にソースから読まれるので、定数ではなく直接書く。
    @Parameter(
        title: "Agents",
        size: [
            .systemSmall: IntentCollectionSize(min: 0, max: 1),
            .systemMedium: IntentCollectionSize(min: 0, max: 4),
            .systemLarge: IntentCollectionSize(min: 0, max: 5),
        ]
    )
    var agents: [AgentEntity]?

    /// 未指定ならアプリ側の並び順をそのまま使う。
    var selectedIDs: [String] { (agents ?? []).map(\.id) }
}
