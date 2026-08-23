import Combine
import Sparkle

/// Sparkleの標準UIと設定値を、SwiftUIから扱うための小さな橋渡し。
/// 更新設定の保存はSparkle自身に任せ、アプリ独自のUserDefaultsは重ねない。
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates: Bool

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard enabled != controller.updater.automaticallyChecksForUpdates else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
