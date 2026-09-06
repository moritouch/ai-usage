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

    private static func query(account: String = NSUserName()) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query().merging([
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new } as CFDictionary,
            &item
        )
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              isValid(value)
        else { return nil }
        return value
    }

    @discardableResult
    static func save(_ raw: String) -> Bool {
        let value = normalized(raw)
        guard isValid(value), let data = value.data(using: .utf8) else { return false }

        let update = SecItemUpdate(
            query() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }

        return SecItemAdd(
            query().merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]) { _, new in new } as CFDictionary,
            nil
        ) == errSecSuccess
    }

    @discardableResult
    static func remove() -> Bool {
        let status = SecItemDelete(query() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 画面には全文を出さない。設定済みだと分かる程度の手掛かりだけ返す。
    static func hint(for value: String) -> String {
        let tail = value.suffix(4)
        return tail.isEmpty ? "…" : "…\(tail)"
    }

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
