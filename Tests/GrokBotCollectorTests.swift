import Foundation
import XCTest

final class GrokBotCollectorTests: XCTestCase {
    private func status(_ raw: [String: Any]) throws -> GrokBotCollector.Status {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(GrokBotCollector.Status.self, from: data)
    }

    /// 実際の応答をそのまま通し、画面に出る値まで組み上がることを固定する。
    func testUsageStatusBecomesAWindowWithItsResetAndPlan() throws {
        let agent = GrokBotCollector.agent(from: try status([
            "currentPeriodStart": "2026-09-05T18:22:04.315Z",
            "nextResetTimestampUtc": "2026-09-09T07:05:17.861Z",
            "usagePercent": 2.142593,
            "hasAvailableUsage": true,
            "hasNonZeroIncludedLimit": true,
            "grokPlanLabel": "X Premium+",
        ]))

        XCTAssertEqual(agent.id, "grok-bot")
        XCTAssertEqual(agent.plan, "X Premium+")
        XCTAssertEqual(agent.status, .ok)

        let window = try XCTUnwrap(agent.windows.first)
        XCTAssertEqual(window.usedPercent, 2.142593, accuracy: 0.0001)
        XCTAssertEqual(window.label, "Period")
        XCTAssertEqual(
            window.resetsAt,
            ISO8601DateFormatter.parsing.date(from: "2026-09-09T07:05:17.861Z")
        )
    }

    /// 上限が無い契約では割合に意味がない。0%のバーを出すと余裕があると誤読させる。
    func testNoIncludedLimitProducesNoWindow() throws {
        let agent = GrokBotCollector.agent(from: try status([
            "usagePercent": 0,
            "hasNonZeroIncludedLimit": false,
            "grokPlanLabel": "X Premium+",
        ]))

        XCTAssertTrue(agent.windows.isEmpty)
        XCTAssertEqual(agent.status, .unavailable)
    }

    func testMissingPercentProducesNoWindow() throws {
        let agent = GrokBotCollector.agent(from: try status(["grokPlanLabel": "X Premium+"]))
        XCTAssertTrue(agent.windows.isEmpty)
        XCTAssertEqual(agent.status, .unavailable)
    }

    /// 保存しているのはCookieヘッダ全体だが、手掛かりとして意味があるのは
    /// セッションCookieの値。Claude側の表示と揃える。
    func testHintShowsTheTailOfTheSessionCookieOnly() {
        let cookie = "workos_id=abc; WorkosCursorSessionToken=longsecret9f2c; csrf-token=xyz"

        XCTAssertEqual(GrokBotSession.hint(for: cookie), "…9f2c")
        XCTAssertFalse(GrokBotSession.hint(for: cookie).contains("longsecret"))
        XCTAssertEqual(GrokBotSession.sessionCookieValue(in: cookie), "longsecret9f2c")
        XCTAssertNil(GrokBotSession.sessionCookieValue(in: "workos_id=abc"))
    }

    /// double-submit方式のCSRF対策向け。Cookieと同じ値をヘッダにも載せる。
    func testCSRFTokenIsTakenFromTheCookie() {
        XCTAssertEqual(
            GrokBotCollector.csrfToken(in: "a=1; csrf-token=tok123; b=2"),
            "tok123"
        )
        XCTAssertNil(GrokBotCollector.csrfToken(in: "a=1; b=2"))
        XCTAssertNil(GrokBotCollector.csrfToken(in: "csrf-token="))
    }

    /// Cookieヘッダへ差し込む値なので、改行を通すとヘッダを分割されてしまう。
    func testSessionValidationRejectsHeaderBreakingValues() {
        let valid = "WorkosCursorSessionToken=abc123; workos_id=xyz"
        XCTAssertTrue(GrokBotSession.isValid(valid))
        XCTAssertEqual(GrokBotSession.normalized("  a=1 ;; b=2 ; junk ; "), "a=1; b=2")

        XCTAssertFalse(GrokBotSession.isValid(""))
        XCTAssertFalse(GrokBotSession.isValid("nocookievalue"))
        XCTAssertFalse(GrokBotSession.isValid("a=1\nSet-Cookie: evil=1"))
        XCTAssertFalse(GrokBotSession.isValid(String(repeating: "a=1; ", count: 3_000)))
    }
}

private extension ISO8601DateFormatter {
    static var parsing: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
