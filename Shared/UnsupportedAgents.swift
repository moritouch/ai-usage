import Foundation

/// 入っているが残量をローカルに出さないツール。
/// 一覧に並べても空の枠が場所を取るだけなので、設定の注記でだけ触れる。
enum UnsupportedAgents {
    private static let known: [(name: String, marker: String)] = [
        ("Gemini CLI", ".gemini"),
        ("Cursor Agent", ".cursor"),
    ]

    static var detected: [String] {
        known
            .filter { FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/\($0.marker)") }
            .map(\.name)
    }
}
