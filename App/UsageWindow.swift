import AppKit
import SwiftUI

/// Dock アイコンから開くウィンドウ。
/// メニューバー常駐だけだと Dock を押しても出す物が無いので、同じ内容を独立窓でも見せる。
@MainActor
final class UsageWindowController {
    private var window: NSWindow?

    func show(model: UsageModel) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: UsagePopoverView(model: model, showsQuit: false).frame(width: 340)
            )
            let created = NSWindow(contentViewController: hosting)
            // title は「ウィンドウ」メニューや支援技術のために残しつつ、
            // タイトルバーには描かせない。名前はコンテンツ側の見出しが持つ。
            created.title = "AI Usage"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.styleMask = [.titled, .closable, .miniaturizable]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 340, height: 560))
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}

/// 設定ウィンドウ。メニューバーのポップオーバーからは開けない大きさなので独立させる。
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(model: UsageModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.title = "AI Usage Settings"
            created.titlebarAppearsTransparent = true
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        window?.title = L10n.text("settings.title", language: model.language)
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func updateLanguage(_ language: AppLanguage) {
        window?.title = L10n.text("settings.title", language: language)
    }
}

/// Staleの意味と、エージェント別の対処方法を表示する独立ウィンドウ。
@MainActor
final class HelpWindowController {
    private var window: NSWindow?

    func show(model: UsageModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: StaleHelpView(model: model))
            let created = NSWindow(contentViewController: hosting)
            created.titlebarAppearsTransparent = true
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.setContentSize(NSSize(width: 500, height: 560))
            created.center()
            window = created
        }
        updateLanguage(model.language)
        window?.level = .normal
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func updateLanguage(_ language: AppLanguage) {
        window?.title = L10n.text("help.windowTitle", language: language)
    }
}

/// Dock アイコンのクリックを拾うためだけのデリゲート。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Dock からの再表示要求。UsageModel 側で差し替える。
    @MainActor static var onReopen: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Self.onReopen?() }
        return true
    }
}
