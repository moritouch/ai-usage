import SwiftUI
import WidgetKit

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView(model: model)
                .environment(\.locale, model.language.locale)
        } label: {
            MenuBarLabel(
                snapshot: model.visibleSnapshot,
                isRefreshing: model.isRefreshing,
                language: model.language
            )
        }
        .menuBarExtraStyle(.window)
    }
}

/// メニューバーに出す要約。最も逼迫しているウィンドウの使用率を出す。
struct MenuBarLabel: View {
    let snapshot: UsageSnapshot
    let isRefreshing: Bool
    let language: AppLanguage

    var body: some View {
        if let headline = snapshot.headline {
            HStack(spacing: 3) {
                if let image = MenuBarGauge.image(percent: headline.window.usedPercent) {
                    Image(nsImage: image)
                } else {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                }
                Text(headline.window.usedText)
                if headline.agent.displayStatus == .stale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                L10n.format(
                    "menubar.summary.format",
                    language: language,
                    headline.agent.name,
                    L10n.windowLabel(headline.window, language: language),
                    headline.window.usedText,
                    headline.agent.displayStatus == .stale
                        ? L10n.text("menubar.staleSuffix", language: language)
                        : ""
                )
            )
        } else {
            HStack(spacing: 3) {
                Image(systemName: isRefreshing
                      ? "arrow.triangle.2.circlepath"
                      : "gauge.with.dots.needle.bottom.50percent")
                Text("—")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                L10n.text(
                    isRefreshing ? "menubar.loading" : "menubar.unavailable",
                    language: language
                )
            )
        }
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot = SnapshotStore.load()
    @Published private(set) var isRefreshing = false
    @Published private(set) var storageError: String?
    @Published private(set) var helpAgentID: String?

    @Published private(set) var language: AppLanguage = LanguagePreference.load()

    /// アプリ本体の更新を管理する。WidgetにはSparkleを含めない。
    let updater = AppUpdater()

    /// 画面に並べるカード。ドラッグ中はここだけを動かして着地点を見せ、
    /// 指を離した時点で永続化する。収集のたびに並びが飛ぶのを防ぐための分離。
    @Published private(set) var orderedAgents: [AgentUsage] = []

    /// いま掴んでいるカード。nil ならドラッグしていない。
    @Published var draggingID: String?

    /// Dock に出すかどうか。LSUIElement で常駐起動しつつ、実行時に切り替える。
    @Published var showsInDock: Bool = UserDefaults.standard.bool(forKey: "showsInDock") {
        didSet {
            UserDefaults.standard.set(showsInDock, forKey: "showsInDock")
            applyActivationPolicy()
        }
    }

    /// 利用者が並べ替えた表示順。空なら自動判定に任せる。
    @Published private(set) var agentOrder: [String] =
        UserDefaults.standard.stringArray(forKey: "agentOrder") ?? []

    /// 設定で伏せたエージェント。収集はするが、どこにも表示しない。
    @Published private(set) var hiddenAgentIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenAgentIDs") ?? [])

    /// 設定画面用。伏せたものも含む全件。
    var allAgents: [AgentUsage] { reordered(snapshot.agents, by: agentOrder) }

    /// 表示対象だけに絞ったスナップショット。メニューバーとウィジェットはこれを見る。
    var visibleSnapshot: UsageSnapshot {
        let visible = reordered(snapshot.agents, by: agentOrder)
            .filter { !hiddenAgentIDs.contains($0.id) }
        return UsageSnapshot(
            updatedAt: snapshot.updatedAt,
            agents: visible,
            preferredAgentID: agentOrder.isEmpty
                ? nil
                : visible.first { !$0.windows.isEmpty }?.id
        )
    }

    func isHidden(_ id: String) -> Bool { hiddenAgentIDs.contains(id) }

    func toggleHidden(_ id: String) {
        var proposed = hiddenAgentIDs
        if proposed.contains(id) { proposed.remove(id) }
        else { proposed.insert(id) }
        applyHiddenAgentIDs(proposed)
    }

    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var dragEndTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var refreshPending = false
    private var lastPublishedAgents: [AgentUsage]?
    private var lastPublishedPreferredID: String?
    private var privateStorageError: String?
    private var publishedStorageError: String?
    private let windowController = UsageWindowController()
    private let settingsController = SettingsWindowController()
    private let helpController = HelpWindowController()

    init() {
        // 初回はシステム言語から決めた値もApp Groupへ確定し、Widgetと揃える。
        LanguagePreference.save(language)
        if let saved = try? SnapshotStore.loadPrivate() {
            snapshot = saved.expiringStaleData()
        } else if let published = try? SnapshotStore.loadPublished() {
            snapshot = published.expiringStaleData()
        }
        applyActivationPolicy()
        AppDelegate.onReopen = { [weak self] in self?.openWindow() }
        syncOrderedAgents()
        // 旧版の共有snapshotに非表示項目が残っていても、起動直後に公開範囲を縮める。
        publishVisible(clearOnFailure: true)
        refresh()
        // Claude の statusLine は起動中つねに書き込むので、短めの間隔で拾う。
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(showsInDock ? .regular : .accessory)
        // Dock から外したらウィンドウも畳む。開いたままだと行き場を失う。
        if !showsInDock { windowController.close() }
    }

    /// Dock アイコンのクリックから呼ばれる。
    func openWindow() {
        windowController.show(model: self)
    }

    func openSettings() {
        // MenuBarExtra のポップオーバーは前面に浮くパネルとして存在するため、
        // 通常レベルの設定ウィンドウを開いてもその後ろに隠れてしまう。先に畳む。
        dismissMenuBarPopover()
        settingsController.show(model: self)
    }

    func openHelp(for agentID: String? = nil) {
        helpAgentID = agentID
        dismissMenuBarPopover()
        helpController.show(model: self)
    }

    func setLanguage(_ proposed: AppLanguage) {
        guard proposed != language else { return }
        LanguagePreference.save(proposed)
        language = proposed
        settingsController.updateLanguage(proposed)
        helpController.updateLanguage(proposed)
        WidgetCenter.shared.reloadTimelines(ofKind: "AIUsageWidget")
    }

    private func dismissMenuBarPopover() {
        for window in NSApp.windows where window.isVisible {
            let kind = String(describing: type(of: window))
            guard kind.contains("MenuBarExtra") || kind.contains("NSStatusBarWindow")
                    || window.level == .popUpMenu
            else { continue }
            window.close()
        }
    }

    /// 伏せたものを除いて共有し、ウィジェットに知らせる。
    @discardableResult
    private func publishVisible(clearOnFailure: Bool = false) -> Bool {
        let visible = visibleSnapshot
        do {
            try SnapshotStore.savePublished(visible)
            publishedStorageError = nil

            let changed = lastPublishedAgents != visible.agents
                || lastPublishedPreferredID != visible.preferredAgentID
            lastPublishedAgents = visible.agents
            lastPublishedPreferredID = visible.preferredAgentID
            if changed { WidgetCenter.shared.reloadTimelines(ofKind: "AIUsageWidget") }
            updateStorageError()
            return true
        } catch {
            publishedStorageError = error.localizedDescription
            if clearOnFailure {
                do { try SnapshotStore.removePublished() }
                catch { publishedStorageError = error.localizedDescription }
            }
            updateStorageError()
            return false
        }
    }

    private func updateStorageError() {
        let errors = [privateStorageError, publishedStorageError].compactMap { $0 }
        storageError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    // MARK: - 並べ替え

    /// SwiftUIのonDragには終了callbackが無いため、欄外で離した場合もmouse-up後に必ず解除する。
    func beginDrag(_ id: String) {
        draggingID = id
        dragEndTask?.cancel()
        dragEndTask = Task { [weak self] in
            do {
                while NSEvent.pressedMouseButtons & 1 != 0 {
                    try await Task.sleep(for: .milliseconds(100))
                }
                // rowのdrop delegateへ先に確定機会を渡す。
                try await Task.sleep(for: .milliseconds(200))
            } catch { return }
            guard let self, self.draggingID == id else { return }
            self.cancelDrag()
        }
    }

    /// ドラッグ中の入れ替え。表示用の配列だけを動かすので即座に、かつ滑らかに反映される。
    func previewMove(_ dragged: String, over target: String) {
        guard dragged != target,
              let from = orderedAgents.firstIndex(where: { $0.id == dragged }),
              let to = orderedAgents.firstIndex(where: { $0.id == target })
        else { return }
        withAnimation(.snappy(duration: 0.22)) {
            let moved = orderedAgents.remove(at: from)
            orderedAgents.insert(moved, at: to)
        }
    }

    /// 指を離した時点で確定して保存する。
    func commitOrder() {
        dragEndTask?.cancel()
        dragEndTask = nil
        draggingID = nil
        persist(orderedAgents.map(\.id))
        resumePendingRefresh()
    }

    func cancelDrag() {
        dragEndTask?.cancel()
        dragEndTask = nil
        draggingID = nil
        syncOrderedAgents()
        resumePendingRefresh()
    }

    func moveAgent(_ id: String, by offset: Int) {
        guard let from = orderedAgents.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, from + offset), orderedAgents.count - 1)
        guard from != to else { return }
        let moved = orderedAgents.remove(at: from)
        orderedAgents.insert(moved, at: to)
        persist(orderedAgents.map(\.id))
    }

    func resetOrder() {
        persist([])
        refresh(force: true)
    }

    private func persist(_ ids: [String]) {
        agentOrder = ids
        UserDefaults.standard.set(ids, forKey: "agentOrder")
        // 保存した順でウィジェットにも反映させる。
        let agents = reordered(snapshot.agents, by: ids)
        snapshot = UsageSnapshot(
            updatedAt: snapshot.updatedAt,
            agents: agents,
            preferredAgentID: ids.isEmpty
                ? nil
                : agents.first { !$0.windows.isEmpty }?.id
        )
        publishVisible()
    }

    private func reordered(_ agents: [AgentUsage], by ids: [String]) -> [AgentUsage] {
        guard !ids.isEmpty else { return agents }
        return agents.enumerated().sorted { lhs, rhs in
            let l = ids.firstIndex(of: lhs.element.id) ?? (ids.count + lhs.offset)
            let r = ids.firstIndex(of: rhs.element.id) ?? (ids.count + rhs.offset)
            return l < r
        }.map(\.element)
    }

    /// 収集結果を表示用の配列へ写す。ドラッグ中は触らない。
    private func syncOrderedAgents() {
        guard draggingID == nil else { return }
        orderedAgents = reordered(snapshot.agents, by: agentOrder).filter {
            $0.status != .notInstalled && !hiddenAgentIDs.contains($0.id)
        }
    }

    // MARK: - 収集

    func refresh(force: Bool = false) {
        // ドラッグ中に並びが差し替わると掴んでいるカードが飛ぶので待つ。
        guard draggingID == nil else {
            refreshPending = true
            return
        }
        if refreshTask != nil {
            guard force else { return }
            refreshTask?.cancel()
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        let order = agentOrder
        refreshTask = Task { [weak self] in
            let fresh = await Task.detached(priority: .utility) {
                await UsageCollector.collectAll(order: order, force: force)
            }.value
            guard !Task.isCancelled, let self,
                  generation == self.refreshGeneration
            else { return }

            let merged = self.mergingUnavailableAgents(in: fresh, with: self.snapshot)
                .expiringStaleData()
            let currentOrder = self.agentOrder
            let currentAgents = self.reordered(merged.agents, by: currentOrder)
            let normalized = UsageSnapshot(
                updatedAt: merged.updatedAt,
                agents: currentAgents,
                preferredAgentID: currentOrder.isEmpty
                    ? nil
                    : currentAgents.first { !$0.windows.isEmpty }?.id
            )
            self.snapshot = normalized
            do {
                try SnapshotStore.savePrivate(normalized)
                self.privateStorageError = nil
            } catch {
                self.privateStorageError = error.localizedDescription
            }
            self.syncOrderedAgents()
            self.isRefreshing = false
            self.refreshTask = nil
            self.publishVisible()
            self.updateStorageError()
        }
    }

    private func resumePendingRefresh() {
        guard refreshPending else { return }
        refreshPending = false
        refresh(force: true)
    }

    /// 一時的なKeychain/API/file read失敗で最後の実測を消さず、明示的なstale値として残す。
    private func mergingUnavailableAgents(
        in fresh: UsageSnapshot,
        with previous: UsageSnapshot
    ) -> UsageSnapshot {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.agents.map { ($0.id, $0) })
        let agents = fresh.agents.map { agent -> AgentUsage in
            guard agent.status == .unavailable,
                  agent.windows.isEmpty,
                  let old = previousByID[agent.id],
                  !old.windows.isEmpty
            else { return agent }
            return AgentUsage(
                id: agent.id,
                name: agent.name,
                plan: old.plan,
                windows: old.windows,
                observedAt: old.observedAt,
                source: old.source,
                status: .stale,
                note: agent.note
            )
        }
        return UsageSnapshot(updatedAt: fresh.updatedAt, agents: agents,
                             preferredAgentID: fresh.preferredAgentID)
    }

    /// 公開snapshotの縮小が成功してから設定を確定する。失敗時はUIも元へ戻す。
    private func applyHiddenAgentIDs(_ proposed: Set<String>) {
        let previous = hiddenAgentIDs
        hiddenAgentIDs = proposed
        syncOrderedAgents()

        guard publishVisible(clearOnFailure: true) else {
            let failure = publishedStorageError ?? "The visible snapshot could not be updated"
            hiddenAgentIDs = previous
            syncOrderedAgents()
            let restored = publishVisible()
            if restored {
                publishedStorageError = "Visibility change was not applied: \(failure)"
                updateStorageError()
            }
            return
        }

        UserDefaults.standard.set(Array(proposed).sorted(), forKey: "hiddenAgentIDs")
    }
}
