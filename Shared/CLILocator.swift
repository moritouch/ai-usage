import Foundation

/// PATH に頼らずコマンドの実体を探す。
///
/// Finder から起動したアプリはシェルの初期化ファイルが通した PATH を受け取らない。
/// よく使われるインストール先を直接見に行く。
enum CLILocator {
    /// 版ごとに bin を持つ管理ツールで、走査が際限なく増えないようにする上限。
    private static let versionLimit = 64

    static func searchPaths() -> [URL] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser

        var paths = [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
        ].map(URL.init(fileURLWithPath:)) + [
            ".local/bin", ".claude/local", ".volta/bin", ".asdf/shims",
            ".bun/bin", ".npm-global/bin", ".npm-packages/bin", "n/bin",
            "Library/pnpm",
        ].map(home.appendingPathComponent)

        // nvm/fnm はNodeのversionごとにbinを持つため、1段だけ展開する。
        for (root, suffix) in [
            (home.appendingPathComponent(".nvm/versions/node"), "bin"),
            (home.appendingPathComponent(".fnm/node-versions"), "installation/bin"),
            (home.appendingPathComponent("Library/Application Support/fnm/node-versions"),
             "installation/bin"),
        ] {
            guard let entries = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            paths += entries.prefix(versionLimit).map { $0.appendingPathComponent(suffix) }
        }
        return paths
    }

    static func locate(_ name: String) -> URL? {
        let manager = FileManager.default
        for directory in searchPaths() {
            let candidate = directory.appendingPathComponent(name)
            if manager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
