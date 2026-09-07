import Foundation
import XCTest

final class GrokBotCollectorTests: XCTestCase {
    /// Grok Bot と Cursor は同じアカウントで動くため、保存先も1つで足りる。
    func testBothRoutesShareOneStoredSession() {
        XCTAssertEqual(CursorSession.service, "jp.co.forestx.aiusage.grokbot-session")
    }

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

    /// double-submit方式のCSRF対策向け。Cookieと同じ値をヘッダにも載せる。
    func testCSRFTokenIsTakenFromTheCookie() {
        XCTAssertEqual(
            CursorAPI.csrfToken(in: "a=1; csrf-token=tok123; b=2"),
            "tok123"
        )
        XCTAssertNil(CursorAPI.csrfToken(in: "a=1; b=2"))
        XCTAssertNil(CursorAPI.csrfToken(in: "csrf-token="))
    }

    /// Cookieヘッダへ差し込む値なので、改行を通すとヘッダを分割されてしまう。
    func testSessionValidationRejectsHeaderBreakingValues() {
        let valid = "WorkosCursorSessionToken=abc123; workos_id=xyz"
        XCTAssertTrue(CursorSession.isValid(valid))
        XCTAssertEqual(CursorSession.normalized("  a=1 ;; b=2 ; junk ; "), "a=1; b=2")

        XCTAssertFalse(CursorSession.isValid(""))
        XCTAssertFalse(CursorSession.isValid("nocookievalue"))
        XCTAssertFalse(CursorSession.isValid("a=1\nSet-Cookie: evil=1"))
        XCTAssertFalse(CursorSession.isValid(String(repeating: "a=1; ", count: 3_000)))
    }
}

private extension ISO8601DateFormatter {
    static var parsing: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
