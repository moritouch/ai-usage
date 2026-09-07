import Foundation

/// cursor.com のダッシュボードAPIへの問い合わせ。Grok Bot と Cursor が共有する。
///
/// 公開されているAPIではない。提供元の変更で壊れる前提で、失敗は素直に
/// 「取得できない」として扱い、古い値を残さない。
enum CursorAPI {
    enum Outcome: Sendable {
        case body(Data)
        case unauthorized
        case unavailable
    }

    private static let base = "https://cursor.com/api/dashboard/"
    private static let maximumResponseBytes = 256 * 1_024
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func post(_ path: String, cookie: String) async -> Outcome {
        guard let url = URL(string: base + path) else { return .unavailable }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // ページから出る要求には自動で付き、CSRF検査がこれを見ている。
        // 付けないと認証が通っていても403になる。
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        if let token = csrfToken(in: cookie) {
            request.setValue(token, forHTTPHeaderField: "x-csrf-token")
        }
        // Cookieは手で組み立てて渡す。URLSessionの管理に任せると差し替えられる。
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            switch http.statusCode {
            case 200:
                guard data.count <= maximumResponseBytes else { return .unavailable }
                return .body(data)
            case 401, 403:
                return .unauthorized
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    /// double-submit方式のCSRF対策向け。Cookieと同じ値をヘッダにも載せる。
    static func csrfToken(in cookie: String) -> String? {
        for pair in cookie.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("csrf-token=") else { continue }
            let value = String(trimmed.dropFirst("csrf-token=".count))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// ミリ秒エポックが文字列で入ってくる。桁を取り違えると数万年先の日付になるため、
    /// 妥当な範囲に収まるものだけ通す。
    static func parseEpochMilliseconds(_ text: String?) -> Date? {
        guard let text, let milliseconds = Double(text), milliseconds.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: milliseconds / 1_000)
        let distance = date.timeIntervalSinceNow
        guard distance.isFinite, distance >= -10 * 365 * 86_400, distance <= 10 * 365 * 86_400
        else { return nil }
        return date
    }
}
