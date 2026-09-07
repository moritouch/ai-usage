import Foundation
import XCTest

final class ClaudeSessionKeyTests: XCTestCase {
    /// ブラウザからのコピーは `sessionKey=...; other=...` の形になりやすい。
    /// そのまま保存するとCookieヘッダが壊れるので、値だけを取り出す。
    func testNormalizationExtractsTheValueFromAPastedCookie() {
        let expected = String(repeating: "a", count: 40)

        XCTAssertEqual(ClaudeSessionKey.normalized(expected), expected)
        XCTAssertEqual(ClaudeSessionKey.normalized("  \(expected)\n"), expected)
        XCTAssertEqual(ClaudeSessionKey.normalized("sessionKey=\(expected)"), expected)
        XCTAssertEqual(
            ClaudeSessionKey.normalized("sessionKey=\(expected); lastActiveOrg=abc"),
            expected
        )
    }

    /// Cookieヘッダへ差し込む値なので、区切り文字や制御文字は通さない。
    func testValidationRejectsValuesThatWouldBreakTheCookieHeader() {
        let valid = String(repeating: "b", count: 40)
        XCTAssertTrue(ClaudeSessionKey.isValid(valid))

        XCTAssertFalse(ClaudeSessionKey.isValid(""))
        XCTAssertFalse(ClaudeSessionKey.isValid("short"))
        XCTAssertFalse(ClaudeSessionKey.isValid("\(valid);injected=1"))
        XCTAssertFalse(ClaudeSessionKey.isValid("\(valid)=x"))
        XCTAssertFalse(ClaudeSessionKey.isValid("\(valid) with space"))
        XCTAssertFalse(ClaudeSessionKey.isValid("\(valid)\nSet-Cookie: evil=1"))
        XCTAssertFalse(ClaudeSessionKey.isValid(String(repeating: "c", count: 5_000)))
    }

    /// 組織IDはURLへ差し込むので、経路を書き換えられる文字を通してはいけない。
    func testOrganizationIdentifierRejectsPathTraversal() {
        XCTAssertTrue(
            ClaudeWebUsageAPI.isSafeIdentifier("0b8c1e2f-3a4b-5c6d-7e8f-9a0b1c2d3e4f")
        )
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier("../../admin"))
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier("abc/usage?x=1"))
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier("abc def"))
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier("short"))
        XCTAssertFalse(ClaudeWebUsageAPI.isSafeIdentifier(String(repeating: "a", count: 65)))
    }
}
