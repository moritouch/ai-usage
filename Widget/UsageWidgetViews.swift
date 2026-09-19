import SwiftUI
import WidgetKit

/// WidgetKitが渡すサイズを読み、描画は `UsageWidgetContent` に任せる。
/// サイズを引数で受ける側に分けておくと、各サイズを画像に描いて確かめられる。
struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: UsageSnapshot
    let language: AppLanguage
    var selectedIDs: [String] = []

    var body: some View {
        UsageWidgetContent(
            family: family, snapshot: snapshot,
            language: language, selectedIDs: selectedIDs
        )
    }
}

/// 表示は一貫して「使用量（used）」。バーの伸びと色の濃さが同じ向きを指すようにする。
/// 5 時間枠のような短い窓はセッション中に真っ先に効いてくるので、目立たせる。
struct UsageWidgetContent: View {
    let family: WidgetFamily
    let snapshot: UsageSnapshot
    let language: AppLanguage
    var selectedIDs: [String] = []

    /// 一覧で描ける量。エージェント数の上限は「ウィジェットを編集」で選べる数
    /// （`SelectAgentsIntent`）と揃える。行は窓1つで1行で、1エージェントが複数の
    /// 窓を持つのでエージェント数とは別に数える。小サイズは一覧を使わない。
    static func capacity(for family: WidgetFamily) -> (rows: Int, agents: Int) {
        switch family {
        // 5エージェント・8行（Claudeの2枠とCodexのモデル別枠を含む）で344pt四方に収まる。
        case .systemLarge: return (rows: 8, agents: 5)
        default: return (rows: 4, agents: 4)
        }
    }

    private var capacity: (rows: Int, agents: Int) { Self.capacity(for: family) }

    /// 選択があればその順、無ければ本体の並び順。窓がない項目も空状態の説明に使う。
    private var configuredAgents: [AgentUsage] {
        guard !selectedIDs.isEmpty else { return snapshot.agents }
        return selectedIDs.compactMap { id in snapshot.agents.first { $0.id == id } }
    }

    private var orderedAgents: [AgentUsage] {
        configuredAgents.filter { !$0.windows.isEmpty }
    }

    /// 上から詰めて、行数かエージェント数のどちらかが上限に達したら打ち切る。
    private var visibleGroups: [(agent: AgentUsage, windows: [UsageWindow])] {
        var groups: [(AgentUsage, [UsageWindow])] = []
        var rows = 0
        for agent in orderedAgents {
            guard rows < capacity.rows, groups.count < capacity.agents else { break }
            // 行数に上限があるため、補助枠より先にプラン枠を採る。
            let take = Array(agent.displayWindows.prefix(capacity.rows - rows))
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
            case .systemLarge: list(detailed: true)
            default: list(detailed: false)
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

    // MARK: - 中・大: エージェント単位でまとめる

    /// 大サイズは縦に余裕があるので、各窓の残りとリセットまでの時間も添える。
    private func list(detailed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI Usage")
                    .font(.caption.weight(.semibold))
                Spacer()
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
                            language: language,
                            showsDetail: detailed
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
    /// 残りとリセットまでの時間を各窓の下に添える（大サイズ）。
    var showsDetail = false

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
                    VStack(alignment: .leading, spacing: 2) {
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
                        if showsDetail {
                            detail(for: window)
                        }
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
                    .accessibilityValue(showsDetail ? resetDescription(for: window) : "")
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

    /// ポップオーバーと同じ「残り 64% · リセット 5日 8時間」。リセットまでは実時間で進む。
    private func detail(for window: UsageWindow) -> some View {
        HStack(spacing: 3) {
            Text(L10n.format("common.left.format", language: language, window.remainingValueText))
            if let resetDate = window.resetsAt {
                Text("·")
                Text(L10n.text("common.reset", language: language))
                Text(resetDate, style: .relative)
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func resetDescription(for window: UsageWindow) -> String {
        guard let resetDate = window.resetsAt else { return "" }
        return L10n.format(
            "popover.reset.accessibility.format",
            language: language,
            resetDate.formatted(
                Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .abbreviated)
                    .locale(language.locale)
            )
        )
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
