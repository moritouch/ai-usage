import Foundation
import Security

/// アプリ内ログインで受け取ったセッションを、AI Usage 専用の Keychain 項目へ置く。
///
/// 他アプリの認証情報には読み書きとも触れない。共用すると macOS が partition list を
/// 書き手へ差し替え、相手側がパスワードを繰り返し求められるようになるため、
/// 取得経路ごとに自前の項目を持つ。
struct WebSessionStore {
    let service: String

    private func query(account: String = NSUserName()) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load(validate: (String) -> Bool) -> String? {
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
              validate(value)
        else { return nil }
        return value
    }

    @discardableResult
    func save(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

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

    /// 最後に保存した時刻。セッションが切れたときに「いつログインしたか」を示す。
    /// 中身に触れずKeychainの属性だけを読むので、値の復号は起きない。
    func savedAt() -> Date? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(
            query().merging([
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]) { _, new in new } as CFDictionary,
            &item
        )
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let saved = attributes[kSecAttrModificationDate as String] as? Date
        else { return nil }
        return saved
    }

    @discardableResult
    func remove() -> Bool {
        let status = SecItemDelete(query() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
