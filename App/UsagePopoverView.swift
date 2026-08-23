import SwiftUI
import UniformTypeIdentifiers

struct UsagePopoverView: View {
    @ObservedObject var model: UsageModel
    /// 常駐のみのモードではアプリメニューが無いので、ポップオーバーだけが終了手段になる。
    /// ウィンドウは Dock モードでしか開かず、標準のアプリメニューと Cmd+Q があるため不要。
    var showsQuit: Bool = true

    private var visibleAgents: [AgentUsage] { model.orderedAgents }
    private var language: AppLanguage { model.language }

    private var isInitialLoading: Bool {
        model.isRefreshing && model.snapshot.updatedAt == .distantPast
    }

    private var allInstalledAgentsAreHidden: Bool {
        let installed = model.allAgents.filter { $0.displayStatus != .notInstalled }
        return !installed.isEmpty && installed.allSatisfy { model.isHidden($0.id) }
    }

    /// Give MenuBarExtra a stable intrinsic height while still capping long lists.
    private var listHeight: CGFloat {
        guard !visibleAgents.isEmpty else { return model.storageError == nil ? 78 : 126 }
        let rows = visibleAgents.reduce(CGFloat.zero) { total, agent in
            let windowCount = max(1, agent.windows.count)
            let windowGaps = CGFloat(max(0, windowCount - 1)) * 7
            return total + 41 + CGFloat(windowCount) * 31 + windowGaps
        }
        let gaps = CGFloat(max(0, visibleAgents.count - 1)) * 8
        let storageNotice: CGFloat = model.storageError == nil ? 0 : 44
        // Font metrics can differ by a few points from the compact row estimate.
        // Leave per-card room so a fully visible list does not retain a tiny scroll range.
        let fittingAllowance = CGFloat(visibleAgents.count) * 8
        return min(460, rows + gaps + storageNotice + 24 + fittingAllowance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(visibleAgents.enumerated()), id: \.element.id) { index, agent in
                        AgentRow(
                            agent: agent,
                            isFirst: agent.id == visibleAgents.first?.id,
                            isDragging: model.draggingID == agent.id,
                            canMoveUp: index > 0,
                            canMoveDown: index < visibleAgents.count - 1,
                            language: language,
                            moveUp: { model.moveAgent(agent.id, by: -1) },
                            moveDown: { model.moveAgent(agent.id, by: 1) },
                            showStaleHelp: { model.openHelp(for: agent.id) }
                        )
                        .onDrag {
                            model.beginDrag(agent.id)
                            return NSItemProvider(object: agent.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: ReorderDropDelegate(targetID: agent.id, model: model)
                        )
                    }
                    if visibleAgents.isEmpty {
                        emptyState
                    }
                    if model.storageError != nil {
                        storageErrorBanner
                    }
                }
                .padding(12)
            }
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)

            Divider()

            footer
        }
        .frame(width: 320)
        .onExitCommand {
            if model.draggingID != nil { model.cancelDrag() }
        }
        .onDisappear {
            if model.draggingID != nil { model.cancelDrag() }
        }
        .environment(\.locale, language.locale)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isInitialLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("popover.checking.title", language: language))
                        .font(.callout.weight(.semibold))
                    Text(L10n.text("popover.checking.detail", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.text("popover.checking.accessibility", language: language))
        } else if allInstalledAgentsAreHidden {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("popover.hidden.title", language: language))
                    .font(.callout.weight(.semibold))
                Text(L10n.text("popover.hidden.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L10n.text("popover.openSettings", language: language)) {
                    model.openSettings()
                }
                    .buttonStyle(.link)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("popover.unsupported.title", language: language))
                    .font(.callout.weight(.semibold))
                Text(L10n.text("popover.unsupported.detail", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var storageErrorBanner: some View {
        Label(
            L10n.text("popover.storageUnavailable", language: language),
            systemImage: "exclamationmark.triangle.fill"
        )
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            .help(L10n.text("popover.storageUnavailable.detail", language: language))
            .accessibilityHint(
                L10n.text("popover.storageUnavailable.detail", language: language)
            )
    }

    private var header: some View {
        HStack {
            Text("AI Usage")
                .font(.headline)
            Text(L10n.text("common.used", language: language))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help(L10n.text("common.refreshNow", language: language))
            .accessibilityLabel(
                L10n.text(
                    model.isRefreshing ? "popover.refreshing" : "popover.refresh.help",
                    language: language
                )
            )

            Button {
                model.openHelp()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("common.help", language: language))
            .accessibilityLabel(L10n.text("popover.help.help", language: language))

            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("common.settings", language: language))
            .accessibilityLabel(L10n.text("popover.settings.help", language: language))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 取得処理そのものが動いているかを、絶対時刻で確認できるようにする。
    private var footer: some View {
        HStack {
            Text(checkedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(L10n.text("popover.checked.help", language: language))
            Spacer()
            if showsQuit {
                Button(L10n.text("common.quit", language: language)) {
                    NSApplication.shared.terminate(nil)
                }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var checkedText: String {
        guard model.snapshot.updatedAt != .distantPast else {
            return L10n.text("popover.notChecked", language: language)
        }
        let date = model.snapshot.updatedAt
        let style = Calendar.current.isDateInToday(date)
            ? Date.FormatStyle(date: .omitted, time: .standard)
            : Date.FormatStyle(date: .abbreviated, time: .standard)
        let formatted = date.formatted(style.locale(language.locale))
        return L10n.format("popover.checked.format", language: language, formatted)
    }

}

/// 掴んでいるカードの上を通ると、その場で並びが入れ替わって着地点が見える。
struct ReorderDropDelegate: DropDelegate {
    let targetID: String
    let model: UsageModel

    func dropEntered(info: DropInfo) {
        guard let dragged = model.draggingID else { return }
        model.previewMove(dragged, over: targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard model.draggingID != nil, info.hasItemsConforming(to: [.text]) else {
            return false
        }
        model.commitOrder()
        return true
    }
}

struct AgentRow: View {
    let agent: AgentUsage
    var isFirst: Bool = false
    var isDragging: Bool = false
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    let language: AppLanguage
    let moveUp: () -> Void
    let moveDown: () -> Void
    let showStaleHelp: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // ウィジェットと同じく左の色帯で所属を示す。
            Capsule()
                .fill(agent.accent)
                .frame(width: 3)

            content
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(agent.accent.opacity(isFirst ? 0.16 : 0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(agent.accent.opacity(isFirst ? 0.5 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.35 : 1)
        .scaleEffect(isDragging ? 0.97 : 1)
        .animation(.snappy(duration: 0.18), value: isDragging)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.format("popover.agentUsage.format", language: language, agent.name)
        )
        .modifier(
            ReorderAccessibilityActions(
                canMoveUp: canMoveUp,
                canMoveDown: canMoveDown,
                language: language,
                moveUp: moveUp,
                moveDown: moveDown
            )
        )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(agent.name)
                    .font(.subheadline.weight(.semibold))
                if let plan = agent.plan {
                    Text(plan)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if agent.displayStatus == .stale {
                    Button(action: showStaleHelp) {
                        Label(
                            L10n.text("common.stale", language: language),
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("popover.stale.help", language: language))
                    .accessibilityLabel(
                        L10n.text("popover.stale.accessibility", language: language)
                    )
                }
                Menu {
                    Button(L10n.text("popover.moveUp", language: language), action: moveUp)
                        .disabled(!canMoveUp)
                    Button(L10n.text("popover.moveDown", language: language), action: moveDown)
                        .disabled(!canMoveDown)
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.text("popover.reorder.help", language: language))
                .accessibilityLabel(
                    L10n.format(
                        "popover.reorder.accessibility.format",
                        language: language,
                        agent.name
                    )
                )
            }

            if agent.windows.isEmpty {
                Text(
                    L10n.agentNote(agent.note, language: language)
                        ?? L10n.text("common.noData", language: language)
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(agent.windows.sorted {
                    ($0.windowSeconds ?? .greatestFiniteMagnitude)
                        < ($1.windowSeconds ?? .greatestFiniteMagnitude)
                }) { window in
                    WindowBar(window: window, language: language)
                }
            }
        }
    }
}

struct WindowBar: View {
    let window: UsageWindow
    let language: AppLanguage


    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                WindowChip(
                    window: window,
                    emphasized: window.isShortWindow,
                    language: language
                )

                UsageBar(percent: window.usedPercent, height: 7, language: language)

                Text(window.usedText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, alignment: .trailing)
            }

            HStack(spacing: 5) {
                Text(
                    L10n.format(
                        "common.left.format",
                        language: language,
                        window.remainingValueText
                    )
                )
                if let resetDate = window.resetsAt {
                    Text("·")
                    Text(L10n.text("common.reset", language: language))
                    Text(resetDate, style: .relative)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 32)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format(
                "popover.quota.accessibility.format",
                language: language,
                L10n.windowLabel(window, language: language)
            )
        )
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var values = [
            L10n.format(
                "popover.used.accessibility.format",
                language: language,
                window.usedText
            ),
            L10n.format(
                "common.left.format",
                language: language,
                window.remainingValueText
            )
        ]
        if let resetDate = window.resetsAt {
            let relative = resetDate.formatted(
                Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .abbreviated)
                    .locale(language.locale)
            )
            values.append(
                L10n.format(
                    "popover.reset.accessibility.format",
                    language: language,
                    relative
                )
            )
        }
        return values.joined(separator: ", ")
    }
}

private struct ReorderAccessibilityActions: ViewModifier {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let language: AppLanguage
    let moveUp: () -> Void
    let moveDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveUp && canMoveDown {
            content
                .accessibilityAction(
                    named: Text(L10n.text("popover.moveUp", language: language)),
                    moveUp
                )
                .accessibilityAction(
                    named: Text(L10n.text("popover.moveDown", language: language)),
                    moveDown
                )
        } else if canMoveUp {
            content.accessibilityAction(
                named: Text(L10n.text("popover.moveUp", language: language)),
                moveUp
            )
        } else if canMoveDown {
            content.accessibilityAction(
                named: Text(L10n.text("popover.moveDown", language: language)),
                moveDown
            )
        } else {
            content
        }
    }
}
