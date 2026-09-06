import Foundation

/// claude.ai の組織エンドポイントから使用量を読む。
///
/// Claude Code の OAuth 資格情報が無い環境（デスクトップ版アプリだけを使っている場合）
/// のための任意経路。公開APIではないため、`ClaudeUsageAPI` が資格情報を得られない
/// ときにだけ使い、既定の経路にはしない。
///
/// 返る本体は `/api/oauth/usage` と同じ形（`five_hour` / `seven_day` / `seven_day_opus`）
/// なので、復号は `ClaudeUsageAPI.Payload` をそのまま使う。
enum ClaudeWebUsageAPI {
    enum Failure: Sendable {
        case unauthorized
        case rateLimited(retryAt: Date?)
        /// Cloudflareのボット検証など、認証の可否を答えていない応答。
        case challenged
        case organizationUnknown
        case networkOrServer
    }

    enum Result: Sendable {
        case success(ClaudeUsageAPI.Payload)
        case failure(Failure)
    }

    private static let base = "https://claude.ai/api"
    private static let maximumResponseBytes = 1 * 1_024 * 1_024
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func fetch(sessionKey: String, now: Date = Date()) async -> Result {
        guard let organization = await organizationID(sessionKey: sessionKey) else {
            return .failure(.organizationUnknown)
        }
        guard let url = URL(string: "\(base)/organizations/\(organization)/usage") else {
            return .failure(.networkOrServer)
        }

        switch await perform(request(url: url, sessionKey: sessionKey)) {
        case let .body(data):
            guard let decoded = try? JSONDecoder().decode(ClaudeUsageAPI.Payload.self, from: data),
                  let payload = ClaudeUsageAPI.validated(decoded, now: now)
            else { return .failure(.networkOrServer) }
            return .success(payload)
        case let .failure(reason):
            return .failure(reason)
        }
    }

    // MARK: - 組織ID

    /// まず `~/.claude.json` を見る。Claudeへログイン済みなら組織IDが入っているので、
    /// 余計な問い合わせをせずに済む。無ければ組織一覧から引く。
    static func organizationID(sessionKey: String) async -> String? {
        if let local = localOrganizationID() { return local }

        guard let url = URL(string: "\(base)/organizations") else { return nil }
        guard case let .body(data) = await perform(request(url: url, sessionKey: sessionKey)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        for row in rows {
            if let uuid = row["uuid"] as? String, isSafeIdentifier(uuid) { return uuid }
        }
        return nil
    }

    static func localOrganizationID() -> String? {
        guard let uuid = localAccount()?["organizationUuid"] as? String,
              isSafeIdentifier(uuid)
        else { return nil }
        return uuid
    }

    /// 契約プラン。claude.ai 経路では応答に含まれないため、ログイン済みの記録から拾う。
    /// `claude_pro` のような識別子で入っているので、表示名への変換は `PlanLabel` に任せる。
    static func localPlan() -> String? {
        localAccount()?["organizationType"] as? String
    }

    private static func localAccount() -> [String: Any]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4 * 1_024 * 1_024 + 1),
              data.count <= 4 * 1_024 * 1_024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["oauthAccount"] as? [String: Any]
    }

    /// UUIDだけを通す。URLへ差し込む値なので経路を書き換えられないようにする。
    static func isSafeIdentifier(_ value: String) -> Bool {
        guard (8...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - 通信

    private enum Response {
        case body(Data)
        case failure(Failure)
    }

    private static func request(url: URL, sessionKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    private static func perform(_ request: URLRequest) async -> Response {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.networkOrServer) }

            switch http.statusCode {
            case 200:
                guard data.count <= maximumResponseBytes else { return .failure(.networkOrServer) }
                // ボット検証はHTMLを200で返すことがある。JSONでなければ認証の可否は不明。
                guard data.first == UInt8(ascii: "{") || data.first == UInt8(ascii: "[")
                else { return .failure(.challenged) }
                return .body(data)
            case 401, 403:
                return .failure(.unauthorized)
            case 429:
                return .failure(.rateLimited(retryAt: retryDate(from: http)))
            case 503:
                return .failure(.challenged)
            default:
                return .failure(.networkOrServer)
            }
        } catch {
            return .failure(.networkOrServer)
        }
    }

    private static func retryDate(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds > 0, seconds <= 24 * 3_600
        else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}
