import AppIntents
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let language: AppLanguage
    /// 「ウィジェットを編集」で選ばれたエージェント。空なら本体の並び順に従う。
    let selectedIDs: [String]
}

struct UsageProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(
            date: Date(), snapshot: .sample,
            language: LanguagePreference.load(), selectedIDs: []
        )
    }

    func snapshot(for configuration: SelectAgentsIntent,
                  in context: Context) async -> UsageEntry {
        return UsageEntry(
            date: Date(),
            // The gallery never needs personal usage values. Keep previews deterministic
            // and read the App Group only for a real widget snapshot.
            snapshot: context.isPreview ? .sample : current(),
            language: LanguagePreference.load(),
            selectedIDs: configuration.selectedIDs
        )
    }

    func timeline(for configuration: SelectAgentsIntent,
                  in context: Context) async -> Timeline<UsageEntry> {
        let entry = UsageEntry(
            date: Date(), snapshot: current(),
            language: LanguagePreference.load(),
            selectedIDs: configuration.selectedIDs
        )
        // This is a best-effort request. WidgetKit may delay it to preserve the
        // system update budget; the containing app also requests reloads on changes.
        return Timeline(entries: [entry],
                        policy: .after(Date().addingTimeInterval(10 * 60)))
    }

    /// 拡張はサンドボックス内で ~/.codex を読めない。
    /// 本体（メニューバーアプリ）が書き出した snapshot だけを読む。
    private func current() -> UsageSnapshot {
        SnapshotStore.load()
    }
}

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget { AIUsageWidget() }
}

struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "AIUsageWidget",
            intent: SelectAgentsIntent.self,
            provider: UsageProvider()
        ) { entry in
            UsageWidgetView(
                snapshot: entry.snapshot,
                language: entry.language,
                selectedIDs: entry.selectedIDs
            )
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI Usage")
        .description(LocalizedStringKey("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// 表示は一貫して「使用量（used）」。バーの伸びと色の濃さが同じ向きを指すようにする。
/// 5 時間枠のような短い窓はセッション中に真っ先に効いてくるので、目立たせる。
struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: UsageSnapshot
    let language: AppLanguage
    var selectedIDs: [String] = []

    /// 描ける行数の上限。中サイズに収まる限界。
    private static let maxRows = 4

    /// 選択があればその順、無ければ本体の並び順。窓がない項目も空状態の説明に使う。
    private var configuredAgents: [AgentUsage] {
        guard !selectedIDs.isEmpty else { return snapshot.agents }
        return selectedIDs.compactMap { id in snapshot.agents.first { $0.id == id } }
    }

    private var orderedAgents: [AgentUsage] {
        configuredAgents.filter { !$0.windows.isEmpty }
    }

    /// 上から詰めて 4 行で打ち切る。1 エージェントが複数の窓を持つので行数で数える。
    private var visibleGroups: [(agent: AgentUsage, windows: [UsageWindow])] {
        var groups: [(AgentUsage, [UsageWindow])] = []
        var rows = 0
        for agent in orderedAgents {
            guard rows < Self.maxRows else { break }
            let sorted = agent.windows.sorted {
                ($0.windowSeconds ?? .greatestFiniteMagnitude)
                    < ($1.windowSeconds ?? .greatestFiniteMagnitude)
            }
            let take = Array(sorted.prefix(Self.maxRows - rows))
            guard !take.isEmpty else { continue }
            groups.append((agent, take))
            rows += take.count
        }
        return groups
    }

    /// 見出し。選択があれば先頭のエージェントを立てる。
    private var headline: (agent: AgentUsage, window: UsageWindow)? {
        if !selectedIDs.isEmpty {
            guard let first = orderedAgents.first,
                  let window = first.headlineWindow
            else { return nil }
            return (agent: first, window: window)
        }
        return snapshot.headline
    }

    private var headlineSecondary: UsageWindow? {
        guard let headline else { return nil }
        return headline.agent.windows.first { $0.id != headline.window.id }
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            default: medium
            }
        }
        .environment(\.locale, language.locale)
    }

    // MARK: - 小: 5 時間枠を主役に

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let headline = headline {
                HStack(spacing: 5) {
                    Circle()
                        .fill(headline.agent.accent)
                        .frame(width: 7, height: 7)
                    Text(headline.agent.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if headline.agent.displayStatus == .stale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityLabel(
                                L10n.text("widget.stale.accessibility", language: language)
                            )
                    }
                    Spacer(minLength: 0)
                    WindowChip(window: headline.window, emphasized: true, language: language)
                }

                Spacer(minLength: 4)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(headline.window.usedText)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .accessibilityLabel(
                            L10n.format(
                                "widget.used.accessibility.format",
                                language: language,
                                headline.window.usedText
                            )
                        )
                }

                UsageBar(percent: headline.window.usedPercent, height: 8, language: language)
                    .padding(.top, 3)
                    .accessibilityHidden(true)

                if let resetDate = headline.window.resetsAt {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .accessibilityHidden(true)
                        Text(resetDate, style: .relative)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        L10n.format(
                            "popover.reset.accessibility.format",
                            language: language,
                            relativeText(resetDate)
                        )
                    )
                }

                Spacer(minLength: 0)

                // 同じエージェントの長い窓は控えめに添える
                if let secondary = headlineSecondary {
                    Divider().padding(.vertical, 4)
                    HStack(spacing: 5) {
                        Text(L10n.windowLabel(secondary, language: language))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        UsageBar(percent: secondary.usedPercent, height: 4, language: language)
                            .accessibilityHidden(true)
                        Text(secondary.usedText)
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .accessibilityLabel(
                                L10n.format(
                                    "widget.used.accessibility.format",
                                    language: language,
                                    secondary.usedText
                                )
                            )
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 中: エージェント単位でまとめる

    private var medium: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI Usage")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(L10n.text("common.used", language: language))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            if visibleGroups.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(visibleGroups, id: \.agent.id) { group in
                        AgentGroupRow(
                            agent: group.agent,
                            windows: group.windows,
                            language: language
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(emptyMessage.title)
                .font(.caption.weight(.semibold))
            Text(emptyMessage.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyMessage: (title: String, detail: String) {
        if snapshot.updatedAt == .distantPast {
            return message("widget.empty.noSnapshot.title", "widget.empty.noSnapshot.detail")
        }
        if !selectedIDs.isEmpty && configuredAgents.isEmpty {
            return message(
                "widget.empty.selectedUnavailable.title",
                "widget.empty.selectedUnavailable.detail"
            )
        }
        if snapshot.agents.isEmpty {
            return message("widget.empty.noVisible.title", "widget.empty.noVisible.detail")
        }
        if configuredAgents.allSatisfy({ $0.displayStatus == .notInstalled }) {
            return message("widget.empty.noSupported.title", "widget.empty.noSupported.detail")
        }
        if let unavailable = configuredAgents.first(where: { $0.windows.isEmpty }) {
            return (
                L10n.text("widget.empty.unavailable.title", language: language),
                L10n.agentNote(unavailable.note, language: language)
                    ?? L10n.text("widget.empty.unavailable.detail", language: language)
            )
        }
        return message("widget.empty.noData.title", "widget.empty.noData.detail")
    }

    private func message(_ titleKey: String, _ detailKey: String) -> (String, String) {
        (
            L10n.text(titleKey, language: language),
            L10n.text(detailKey, language: language)
        )
    }

    private func relativeText(_ date: Date) -> String {
        date.formatted(
            Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .abbreviated)
                .locale(language.locale)
        )
    }

}

/// エージェント 1 つを 1 枚のカードにまとめる。
/// 左の色帯と淡い背景で「どこからどこまでが同じアプリか」を一目で分かるようにする。
struct AgentGroupRow: View {
    let agent: AgentUsage
    /// 行数上限で絞り込んだあとの窓。呼び出し側が短い順に整えて渡す。
    let windows: [UsageWindow]
    let language: AppLanguage

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // 左の色帯。カードの高さいっぱいに伸ばして所属を示す。
            Capsule()
                .fill(agent.accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(agent.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if agent.displayStatus == .stale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.orange)
                            .accessibilityLabel(
                                L10n.text("widget.stale.accessibility", language: language)
                            )
                    }
                }
                if let plan = agent.plan {
                    Text(plan)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 84, alignment: .leading)

            VStack(spacing: 4) {
                ForEach(windows) { window in
                    HStack(spacing: 6) {
                        WindowChip(
                            window: window,
                            emphasized: window.isShortWindow,
                            language: language
                        )
                        UsageBar(percent: window.usedPercent, height: 6, language: language)
                        Text(window.usedText)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        L10n.format(
                            "widget.agentUsed.accessibility.format",
                            language: language,
                            L10n.windowLabel(window, language: language),
                            window.usedText
                        )
                    )
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(agent.accent.opacity(0.10))
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension UsageSnapshot {
    /// ギャラリーのプレビュー用。
    static let sample = UsageSnapshot(updatedAt: Date(), agents: [
        AgentUsage(id: "claude-code", name: "Claude Code", plan: "Max",
                   windows: [
                       UsageWindow(id: "five_hour", label: "5h", usedPercent: 27,
                                   resetsAt: Date().addingTimeInterval(9_000),
                                   windowSeconds: 5 * 3_600),
                       UsageWindow(id: "seven_day", label: "7d", usedPercent: 30,
                                   resetsAt: Date().addingTimeInterval(320_000),
                                   windowSeconds: 7 * 86_400),
                   ],
                   observedAt: Date(), source: "usage API", status: .ok, note: nil),
        AgentUsage(id: "codex", name: "Codex", plan: "Pro",
                   windows: [
                       UsageWindow(id: "w10080", label: "7d", usedPercent: 88,
                                   resetsAt: Date().addingTimeInterval(560_000),
                                   windowSeconds: 7 * 86_400),
                   ],
                   observedAt: Date(), source: "session log", status: .ok, note: nil),
        AgentUsage(id: "grok", name: "Grok", plan: "X Premium+",
                   windows: [
                       UsageWindow(id: "grok_period", label: "7d", usedPercent: 0,
                                   resetsAt: Date().addingTimeInterval(120_000),
                                   windowSeconds: 7 * 86_400),
                   ],
                   observedAt: Date(), source: "billing log", status: .ok, note: nil),
    ])
}
