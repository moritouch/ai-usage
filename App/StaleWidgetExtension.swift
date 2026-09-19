import Darwin
import Foundation
import WidgetKit

/// アップデート前の版のまま動き続けるウィジェット拡張を止める。
///
/// Sparkleはアプリを置き換えるが、動いている拡張プロセスは止めない。macOS 27.2以降の
/// WidgetKitは、拡張が描いた内容を保存するときにLaunchServicesの版と照合し、食い違うと
/// `ValidationError.bundleStubNotSupported`（"Bundle version did not match"）で拒否する。
/// 旧版のプロセスが残る限りウィジェットは仮表示のまま止まるので、版が変わって初めて
/// 起動したときに止める。止めた拡張は、次の更新要求でWidgetKitが新しい版から起動し直す。
enum StaleWidgetExtension {
    private static let lastLaunchedBuildKey = "lastLaunchedBuild"
    private static let executableSuffix = "/AIUsageWidget.appex/Contents/MacOS/AIUsageWidget"

    @MainActor
    static func terminateIfAppWasUpdated(defaults: UserDefaults = .standard) {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let previous = defaults.string(forKey: lastLaunchedBuildKey)
        defaults.set(build, forKey: lastLaunchedBuildKey)
        guard previous != build else { return }

        // 旧版の実行ファイルは置き換えで別の場所へ移っていることがあるので、末尾で見分ける。
        // killは同じ利用者のプロセスにしか届かない。
        let stopped = runningProcesses(whosePathEndsWith: executableSuffix)
            .filter { kill($0, SIGTERM) == 0 }
        if !stopped.isEmpty {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func runningProcesses(whosePathEndsWith suffix: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // 数えてから取るまでの間に増えても取りこぼさないよう、余裕を持たせる。
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }

        let own = getpid()
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(filled)).filter { pid in
            guard pid > 0, pid != own,
                  proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0
            else { return false }
            return String(cString: buffer).hasSuffix(suffix)
        }
    }
}
