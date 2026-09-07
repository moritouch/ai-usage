import Foundation
import Security

/// 利用者が自分で貼り付けた claude.ai の session key を、AI Usage 専用の Keychain 項目へ置く。
///
/// Claude Code の `Claude Code-credentials` には触れない。あちらへ書き込むと macOS が
/// partition list を書き手へ差し替えてしまい、Claude Code 側がパスワードを繰り返し
/// 求められるようになるため、共用そのものを避ける。
///
/// これはアカウント全体に効く認証情報で、スコープ付きOAuthトークンより権限が広い。
/// 既定の取得経路にはせず、OAuth資格情報が無いときの任意手段として扱う。
enum ClaudeSessionKey {
    static let service = "jp.co.forestx.aiusage.claude-session"
    private static let store = WebSessionStore(service: service)

    static func load() -> String? { store.load(validate: isValid) }

    @discardableResult
    static func save(_ raw: String) -> Bool {
        let value = normalized(raw)
        guard isValid(value) else { return false }
        return store.save(value)
    }

    @discardableResult
    static func remove() -> Bool { store.remove() }

    /// 最後にログインした時刻。切れたときに古さを判断できるようにする。
    static func savedAt() -> Date? { store.savedAt() }

    /// `sessionKey=` 付きで貼られても、前後に空白や後続のCookieが入っても受け取れるようにする。
    static func normalized(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "sessionKey=") {
            value = String(value[range.upperBound...])
        }
        if let semicolon = value.firstIndex(of: ";") {
            value = String(value[..<semicolon])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cookie値として送れる文字だけを許す。
    static func isValid(_ value: String) -> Bool {
        guard value.count >= 16, value.utf8.count <= 4_096 else { return false }
        return value.unicodeScalars.allSatisfy {
            (0x21...0x7E).contains($0.value) && $0.value != 0x3B && $0.value != 0x3D
        }
    }
}
