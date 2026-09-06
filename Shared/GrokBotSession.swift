import Foundation

/// Grok Bot（cursor.com 基盤）のセッション。
///
/// 使用量はローカルに一切残らず、Grok Bot 自身が持つトークンは safeStorage で
/// 暗号化されている。他アプリの暗号化ストアを開けにいくのは避けたいので、
/// 利用者にアプリ内で cursor.com へログインしてもらい、その Cookie だけを預かる。
enum GrokBotSession {
    static let service = "jp.co.forestx.aiusage.grokbot-session"
    private static let store = WebSessionStore(service: service)

    /// 送るのは Cookie ヘッダそのもの。どの Cookie が要るかは相手側の都合で変わるため、
    /// 名前を決め打ちせずログイン時のものをまとめて預かる。
    static func load() -> String? { store.load(validate: isValid) }

    @discardableResult
    static func save(_ raw: String) -> Bool {
        let value = normalized(raw)
        guard isValid(value) else { return false }
        return store.save(value)
    }

    @discardableResult
    static func remove() -> Bool { store.remove() }

    /// 画面には全文を出さない。設定済みだと分かる程度の手掛かりだけ返す。
    static func hint(for value: String) -> String {
        let count = value.split(separator: ";").count
        return "\(count)"
    }

    static func normalized(_ raw: String) -> String {
        raw.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains("=") }
            .joined(separator: "; ")
    }

    /// Cookie ヘッダとして送れる文字だけを許す。改行を通すとヘッダを分割されてしまう。
    static func isValid(_ value: String) -> Bool {
        guard value.count >= 8, value.utf8.count <= 8_192, value.contains("=") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (0x20...0x7E).contains(scalar.value)
        }
    }
}
