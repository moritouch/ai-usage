import Foundation

/// Claude Code の `/usage` が叩くのと同じ OAuth エンドポイント。
///
/// statusLine と違い、Claude Code が動いていなくても現在値を取れる。
/// ただし User-Agent が `claude-code/<version>` でないと厳しい 429 バケットに落ちるため、
/// ヘッダを揃えたうえで最短 180 秒間隔に制限する。
actor ClaudeUsageAPI {
    static let shared = ClaudeUsageAPI()

    struct Window: Decodable, Sendable {
        let utilization: Double?
        let resets_at: String?

        var resetDate: Date? {
            guard let resets_at else { return nil }
            return ClaudeUsageAPI.parseISO8601(resets_at)
        }
    }

    struct Payload: Decodable, Sendable {
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
    }

    struct FetchResult: Sendable {
        let payload: Payload
        let observedAt: Date
        let plan: String?
        /// 最後の通信が失敗した、または実測から 6 時間以上経っている。
        let isStale: Bool
    }

    enum FailureReason: Sendable {
        case credentialUnavailable
        case unauthorized
        case rateLimited
        case networkOrServer
    }

    enum FetchResponse: Sendable {
        case result(FetchResult)
        case unavailable(FailureReason)
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// 180 秒 TTL。60 秒ごとのリフレッシュから呼ばれても実際の通信は 3 分に 1 回。
    private static let minimumInterval: TimeInterval = 180
    private static let staleInterval: TimeInterval = 6 * 3_600
    private static let maximumBackoff: TimeInterval = 30 * 60
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    private struct Cache {
        let payload: Payload
        let at: Date
        let plan: String?
    }

    private enum AttemptOutcome: Sendable {
        case success(Payload, plan: String?)
        case rateLimited(retryAt: Date?)
        case unauthorized
        case failed
    }

    private var cached: Cache?
    private var nextAttemptAt: Date?
    private var consecutiveFailures = 0
    private var lastFailure: FailureReason?
    private var inFlight: (id: UUID, task: Task<AttemptOutcome, Never>)?

    /// 直近の取得結果。通信できなければキャッシュ、無ければ失敗理由を返す。
    func fetch() async -> FetchResponse {
        let now = Date()

        // Actor は await 中に再入されるため、進行中の通信を明示的に共有する。
        if let inFlight {
            return await completeAttempt(id: inFlight.id, task: inFlight.task)
        }

        if let cached {
            let age = now.timeIntervalSince(cached.at)
            if age.isFinite, age >= 0, age < Self.minimumInterval {
                return cachedResponse(now: now, forceStale: false)
            }
        }
        if let nextAttemptAt, now < nextAttemptAt {
            return cachedResponse(now: now, forceStale: true)
        }

        guard let credential = ClaudeKeychain.credential() else {
            recordFailure(now: now, reason: .credentialUnavailable)
            return cachedResponse(now: now, forceStale: true)
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(ClaudeKeychain.installedVersion())",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let id = UUID()
        let task = Task {
            await Self.perform(request, plan: credential.subscriptionType)
        }
        inFlight = (id, task)
        return await completeAttempt(id: id, task: task)
    }

    private func completeAttempt(id: UUID, task: Task<AttemptOutcome, Never>) async -> FetchResponse {
        let outcome = await task.value
        let now = Date()

        // 同じ Task を待った複数 caller のうち、最初に Actor へ戻ったものだけが反映する。
        if inFlight?.id == id {
            inFlight = nil
            apply(outcome, now: now)
        }
        return cachedResponse(now: now, forceStale: lastFailure != nil)
    }

    private func apply(_ outcome: AttemptOutcome, now: Date) {
        switch outcome {
        case let .success(payload, plan):
            cached = Cache(payload: payload, at: now, plan: plan)
            consecutiveFailures = 0
            nextAttemptAt = nil
            lastFailure = nil

        case let .rateLimited(retryAt):
            consecutiveFailures += 1
            let floor = now.addingTimeInterval(Self.minimumInterval)
            nextAttemptAt = max(retryAt ?? now.addingTimeInterval(600), floor)
            lastFailure = .rateLimited

        case .unauthorized:
            consecutiveFailures += 1
            nextAttemptAt = now.addingTimeInterval(15 * 60)
            lastFailure = .unauthorized

        case .failed:
            recordFailure(now: now, reason: .networkOrServer)
        }
    }

    private func recordFailure(now: Date, reason: FailureReason) {
        consecutiveFailures += 1
        let exponent = min(max(consecutiveFailures - 1, 0), 4)
        let delay = min(
            Self.maximumBackoff,
            Self.minimumInterval * pow(2, Double(exponent))
        )
        nextAttemptAt = now.addingTimeInterval(delay)
        lastFailure = reason
    }

    private func cachedResponse(now: Date, forceStale: Bool) -> FetchResponse {
        guard let cached else {
            return .unavailable(lastFailure ?? .networkOrServer)
        }
        let age = now.timeIntervalSince(cached.at)
        return .result(FetchResult(
            payload: cached.payload,
            observedAt: cached.at,
            plan: cached.plan,
            isStale: forceStale || !age.isFinite || age < 0 || age > Self.staleInterval
        ))
    }

    private static func perform(_ request: URLRequest, plan: String?) async -> AttemptOutcome {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            let status = http.statusCode

            if status == 429 {
                return .rateLimited(retryAt: retryDate(from: http, now: Date()))
            }
            if status == 401 || status == 403 { return .unauthorized }
            guard status == 200, data.count <= maximumResponseBytes else { return .failed }

            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            guard let payload = validated(decoded, now: Date()) else { return .failed }
            return .success(payload, plan: plan)
        } catch {
            return .failed
        }
    }

    private static func validated(_ payload: Payload, now: Date) -> Payload? {
        func validWindow(_ window: Window?) -> Window? {
            guard let window,
                  let utilization = window.utilization,
                  utilization.isFinite,
                  (0...100).contains(utilization)
            else { return nil }

            if window.resets_at != nil {
                guard let date = window.resetDate else { return nil }
                let distance = date.timeIntervalSince(now)
                guard distance.isFinite, abs(distance) <= 10 * 365 * 86_400 else { return nil }
            }
            return window
        }

        let result = Payload(
            five_hour: validWindow(payload.five_hour),
            seven_day: validWindow(payload.seven_day),
            seven_day_opus: validWindow(payload.seven_day_opus)
        )
        guard result.five_hour != nil || result.seven_day != nil || result.seven_day_opus != nil
        else { return nil }
        return result
    }

    private static func retryDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(min(seconds, 7 * 86_400))
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let parsed = formatter.date(from: raw) else { return nil }
        return min(max(parsed, now), now.addingTimeInterval(7 * 86_400))
    }
}
