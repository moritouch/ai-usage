import Foundation
import Security

/// Claude Code が Keychain に保存している OAuth トークンを読む。
///
/// 読むのは利用者本人のトークンで、送り先は Anthropic の usage エンドポイントのみ。
/// Claude Code の `/usage` と同じことをアプリ側から行うための入口。
/// 別アプリからの参照になるため初回は macOS が許可ダイアログを出す。
/// 「常に許可」を選べば以降は無人で読める。
enum ClaudeKeychain {
    struct OAuthCredential: Sendable {
        let accessToken: String
        let subscriptionType: String?
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
            let subscriptionType: String?
        }
        let claudeAiOauth: OAuth?
    }

    /// 契約プラン名（"max" など）。無い版もあるので任意項目として扱う。
    static func subscriptionType() -> String? {
        credential()?.subscriptionType
    }

    static func accessToken() -> String? {
        credential()?.accessToken
    }

    /// API 呼び出し 1 回につき Keychain を 1 回だけ読むためのスナップショット。
    static func credential() -> OAuthCredential? {
        guard let oauth = readOAuth() else { return nil }
        // expiresAt はミリ秒。期限切れならリフレッシュは Claude Code 側に任せ、ここでは諦める。
        if let expiresAt = oauth.expiresAt {
            guard expiresAt.isFinite else { return nil }
            if Date(timeIntervalSince1970: expiresAt / 1_000) < Date() { return nil }
        }
        guard isSafeHeaderValue(oauth.accessToken), oauth.accessToken.count <= 16_384 else {
            return nil
        }
        let subscription = oauth.subscriptionType.flatMap(sanitizedMetadata)
        return OAuthCredential(accessToken: oauth.accessToken, subscriptionType: subscription)
    }

    private static func readOAuth() -> Credentials.OAuth? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        else { return nil }
        return credentials.claudeAiOauth
    }

    /// User-Agent 用。`claude-code/<version>` でないと厳しい 429 バケットに落ちるため、
    /// 実際にこのマシンで動いている Claude Code のバージョンを転写する。
    static func installedVersion() -> String {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: projects, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return fallbackVersion }

        var newest: (url: URL, modified: Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.modified { newest = (url, modified) }
        }

        guard let file = newest?.url,
              let data = readTail(of: file, maximumBytes: versionTailBytes)
        else { return fallbackVersion }

        for rawLine in data.split(separator: 0x0A).reversed().prefix(100) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  let version = object["version"] as? String,
                  isSafeVersion(version)
            else { continue }
            return version
        }
        return fallbackVersion
    }

    /// オフセットが UTF-8 の途中に入っても、最初の不完全な行を捨てて行境界から返す。
    private static func readTail(of url: URL, maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let count = min(UInt64(maximumBytes), size)
        let offset = size - count
        do {
            try handle.seek(toOffset: offset)
            guard var data = try handle.read(upToCount: Int(count)) else { return nil }
            if offset > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else { return nil }
                let start = data.index(after: newline)
                data = start < data.endIndex ? Data(data[start...]) : Data()
            }
            return data
        } catch {
            return nil
        }
    }

    private static func isSafeVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
                return true
            case 0x2B, 0x2D, 0x2E, 0x5F: // + - . _
                return true
            default:
                return false
            }
        }
    }

    private static func isSafeHeaderValue(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    private static func sanitizedMetadata(_ value: String) -> String? {
        let scalars = value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(128))
    }

    private static let versionTailBytes = 256 * 1_024
    private static let fallbackVersion = "2.1.221"
}
