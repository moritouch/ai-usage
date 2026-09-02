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
        let refreshToken: String?
        let expiresAt: Date?
        let scopes: [String]
        let subscriptionType: String?
        let clientID: String?

        /// 同じservice名の別accountを誤更新しないためのKeychain item識別子。
        fileprivate let persistentRef: Data
    }

    enum ReadFailure: Sendable {
        case notFound
        case accessDenied
        case malformed
        case expired
        /// 項目はあるが `claudeAiOauth` が無い。デスクトップ版Claudeだけを使うと
        /// 同じ項目へ `mcpOAuth` しか書かれず、この状態になる。
        case notLinked
    }

    enum CredentialState: Sendable {
        case valid(OAuthCredential)
        case refreshable(OAuthCredential)
        case unavailable(ReadFailure)
    }

    enum SaveResult: Sendable {
        case saved
        case changed(CredentialState)
        case failed
    }

    private struct Credentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
            let scopes: [String]?
            let subscriptionType: String?
            let clientId: String?
        }
        let claudeAiOauth: OAuth?
    }

    private struct KeychainItem {
        let data: Data
        let persistentRef: Data
    }

    /// Keychain項目の中身の種類。
    ///
    /// 同じ項目をターミナル版CLI（`claudeAiOauth`）とデスクトップ版のMCP OAuth
    /// （`mcpOAuth`）が共有するため、「壊れている」と「CLIがまだ書いていない」を
    /// 取り違えると案内が的外れになる。読み取り前にここで分ける。
    enum PayloadShape: Sendable, Equatable {
        case usable
        case notLinked
        case malformed
    }

    static func payloadShape(_ data: Data) -> PayloadShape {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .malformed }
        guard let oauth = root["claudeAiOauth"] else { return .notLinked }
        return oauth is [String: Any] ? .usable : .malformed
    }

    /// `~/.claude.json` に `oauthAccount` があれば、どこかでClaudeへログイン済み。
    /// CLIトークンが無い理由が「未ログイン」なのか「CLIを一度も使っていない」なのかを
    /// 切り分けて、案内先をターミナルログインに寄せるために使う。
    static func hasSignedInAccount() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = readBoundedFile(at: url, maximumBytes: accountFileMaximumBytes),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["oauthAccount"] is [String: Any]
    }

    /// 契約プラン名（"max" など）。無い版もあるので任意項目として扱う。
    static func subscriptionType() -> String? {
        switch credentialState() {
        case let .valid(credential), let .refreshable(credential):
            return credential.subscriptionType
        case .unavailable:
            return nil
        }
    }

    static func accessToken() -> String? {
        credential()?.accessToken
    }

    /// 有効なaccess tokenだけを返す互換API。
    static func credential() -> OAuthCredential? {
        guard case let .valid(credential) = credentialState() else { return nil }
        return credential
    }

    /// Keychainの読取失敗と、更新可能な期限切れを区別する。
    /// Claude Codeと同様に期限の5分前からrefresh対象にする。
    static func credentialState(
        now: Date = Date(), refreshSkew: TimeInterval = 5 * 60
    ) -> CredentialState {
        let (status, item) = readRawItem()
        guard status == errSecSuccess, let item else {
            switch status {
            case errSecItemNotFound:
                return .unavailable(.notFound)
            case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
                return .unavailable(.accessDenied)
            default:
                return .unavailable(.malformed)
            }
        }

        switch payloadShape(item.data) {
        case .malformed: return .unavailable(.malformed)
        case .notLinked: return .unavailable(.notLinked)
        case .usable: break
        }

        guard let oauth = try? JSONDecoder().decode(Credentials.self, from: item.data).claudeAiOauth,
              let credential = validatedCredential(oauth, persistentRef: item.persistentRef)
        else { return .unavailable(.malformed) }

        if let expiresAt = credential.expiresAt,
           expiresAt <= now.addingTimeInterval(max(0, refreshSkew)) {
            return credential.refreshToken == nil
                ? .unavailable(.expired)
                : .refreshable(credential)
        }
        return .valid(credential)
    }

    /// refresh tokenを回転させる前に、同じKeychain itemへ安全に書き戻せることを確認する。
    /// 同じdataを書くだけなので、失敗時はOAuth refreshを開始しない。
    static func prepareForRefresh(_ expected: OAuthCredential) -> Bool {
        let (status, item) = readRawItem()
        guard status == errSecSuccess, let item,
              item.persistentRef == expected.persistentRef,
              rawCredentialMatches(item.data, expected: expected)
        else { return false }

        return SecItemUpdate(
            updateQuery(for: expected) as CFDictionary,
            [kSecValueData as String: item.data] as CFDictionary
        ) == errSecSuccess
    }

    /// Claude Codeのrefresh tokenは回転するため、access/refresh両方が読取時と一致する場合だけ
    /// 未知fieldを残したままKeychainへ書き戻す。競合時は新しい兄弟書込みを採用する。
    static func saveRefreshedCredential(
        expected: OAuthCredential,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scopes: [String]? = nil
    ) -> SaveResult {
        for attempt in 0..<3 {
            let (status, item) = readRawItem()
            guard status == errSecSuccess else {
                if attempt < 2, shouldRetryReadFailure(status) {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }
                return .failed
            }
            guard let item else { return .failed }

            guard item.persistentRef == expected.persistentRef,
                  rawCredentialMatches(item.data, expected: expected)
            else {
                return .changed(credentialState())
            }
            guard let updated = updatedCredentialData(
                item.data,
                expectedAccessToken: expected.accessToken,
                expectedRefreshToken: expected.refreshToken,
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                scopes: scopes
            ) else { return .failed }

            let updateStatus = SecItemUpdate(
                updateQuery(for: expected) as CFDictionary,
                [kSecValueData as String: updated] as CFDictionary
            )
            if updateStatus == errSecSuccess { return .saved }
            if [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled]
                .contains(updateStatus) {
                return .failed
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.05) }
        }
        return .failed
    }

    /// 明示的な拒否・キャンセルや項目削除は再試行せず、確認dialogの連続表示を避ける。
    static func shouldRetryReadFailure(_ status: OSStatus) -> Bool {
        ![
            errSecItemNotFound,
            errSecAuthFailed,
            errSecInteractionNotAllowed,
            errSecUserCanceled,
        ].contains(status)
    }

    /// JSON mergeの純粋部分。Keychainのsibling keysと将来fieldを消さない。
    static func updatedCredentialData(
        _ data: Data,
        expectedAccessToken: String,
        expectedRefreshToken: String?,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scopes: [String]? = nil
    ) -> Data? {
        guard isSafeToken(accessToken), isSafeToken(refreshToken),
              expiresAt.timeIntervalSince1970.isFinite,
              expiresAt > Date(timeIntervalSince1970: 0),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              oauth["accessToken"] as? String == expectedAccessToken,
              oauth["refreshToken"] as? String == expectedRefreshToken
        else { return nil }

        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1_000
        if let scopes {
            oauth["scopes"] = scopes
        }
        root["claudeAiOauth"] = oauth
        guard JSONSerialization.isValidJSONObject(root) else { return nil }
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func rawCredentialMatches(
        _ data: Data, expected: OAuthCredential
    ) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any]
        else { return false }
        return oauth["accessToken"] as? String == expected.accessToken
            && oauth["refreshToken"] as? String == expected.refreshToken
            && oauth["clientId"] as? String == expected.clientID
    }

    private static func validatedCredential(
        _ oauth: Credentials.OAuth,
        persistentRef: Data
    ) -> OAuthCredential? {
        guard isSafeToken(oauth.accessToken) else { return nil }

        let refreshToken: String?
        if let raw = oauth.refreshToken {
            guard isSafeToken(raw) else { return nil }
            refreshToken = raw
        } else {
            refreshToken = nil
        }

        let expiresAt: Date?
        if let raw = oauth.expiresAt {
            guard raw.isFinite else { return nil }
            let parsed = Date(timeIntervalSince1970: raw / 1_000)
            guard parsed.timeIntervalSince1970.isFinite else { return nil }
            expiresAt = parsed
        } else {
            expiresAt = nil
        }

        let scopes = (oauth.scopes ?? []).compactMap(sanitizedMetadata)
        let subscription = oauth.subscriptionType.flatMap(sanitizedMetadata)
        let clientID: String?
        if let raw = oauth.clientId {
            guard isSafeClientID(raw) else { return nil }
            clientID = raw
        } else {
            clientID = nil
        }
        return OAuthCredential(
            accessToken: oauth.accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: scopes,
            subscriptionType: subscription,
            clientID: clientID,
            persistentRef: persistentRef
        )
    }

    private static func readRawItem() -> (OSStatus, KeychainItem?) {
        let query = keychainQuery().merging([
            kSecReturnData as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let values = item as? [String: Any],
              let data = values[kSecValueData as String] as? Data,
              let persistentRef = values[kSecValuePersistentRef as String] as? Data
        else { return (status, nil) }
        return (status, KeychainItem(data: data, persistentRef: persistentRef))
    }

    /// Claude Codeはserviceに加えてmacOS usernameをaccountへ保存する。
    /// 同じservice名の別accountを読み取らないよう両方で選択する。
    static func keychainQuery(accountName: String = NSUserName()) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: accountName,
        ]
    }

    /// macOSではpersistent refをkSecMatchItemListへ渡して更新対象を1件に固定する。
    private static func updateQuery(for credential: OAuthCredential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchItemList as String: [credential.persistentRef],
        ]
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

    /// 先頭から上限バイトまで読む。上限を超えるファイルは扱わない。
    private static func readBoundedFile(at url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maximumBytes + 1),
              data.count <= maximumBytes
        else { return nil }
        return data
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

    private static func isSafeToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 16_384 else { return false }
        return value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    private static func isSafeClientID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
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
    private static let accountFileMaximumBytes = 4 * 1_024 * 1_024
    private static let fallbackVersion = "2.1.221"
}
