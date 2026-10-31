import Foundation
import XCTest

/// 2026年10月の応答から入った `limits` 配列を読めること。
/// 5時間制限が外れた環境では `session` が来なくなり、モデル別の週枠は
/// `weekly_scoped` へ移ったので、固定キーだけでは追えない。
final class ClaudeLimitsTests: XCTestCase {
    private func payload(_ json: String) throws -> ClaudeUsageAPI.Payload {
        try JSONDecoder().decode(ClaudeUsageAPI.Payload.self, from: Data(json.utf8))
    }

    private let live = """
    {"five_hour":{"utilization":5,"resets_at":"2026-10-31T11:50:00.129835+00:00"},
     "seven_day":{"utilization":1,"resets_at":"2026-11-07T08:00:00.129857+00:00"},
     "seven_day_opus":null,
     "limits":[
       {"group":"session","kind":"session","percent":5,"scope":null,
        "resets_at":"2026-10-31T11:50:00.063641+00:00"},
       {"group":"weekly","kind":"weekly_all","percent":1,"scope":null,
        "resets_at":"2026-11-07T08:00:00.063659+00:00"},
       {"group":"weekly","kind":"weekly_scoped","percent":0,
        "scope":{"model":{"display_name":"Fable","id":null},"surface":null},
        "resets_at":"2026-11-07T08:00:00+00:00"}]}
    """

    func testReadsEveryLimitIncludingTheModelScopedWeekly() throws {
        let limits = try XCTUnwrap(payload(live).limits)
        let windows = ClaudeCollector.windows(from: limits)

        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(windows.map(\.label), ["5h", "7d", "Fable 7d"])
        XCTAssertEqual(windows.map(\.usedPercent), [5, 1, 0])
        // 使っていないモデルは0%のまま。代表値に選ばれて「余裕がある」と誤読させない。
        XCTAssertEqual(windows.map(\.isSupplementary), [false, false, true])
        XCTAssertNotNil(windows[0].resetsAt)
    }

    /// 認証済みUltraでは5時間制限が外れる。枠が1つ減るだけで、残りはそのまま出ること。
    func testDropsTheSessionWindowWhenTheAccountNoLongerHasOne() throws {
        let json = """
        {"limits":[{"group":"weekly","kind":"weekly_all","percent":12,
                    "resets_at":"2026-11-07T08:00:00+00:00","scope":null}]}
        """
        let windows = ClaudeCollector.windows(from: try XCTUnwrap(payload(json).limits))
        XCTAssertEqual(windows.map(\.id), ["seven_day"])
        XCTAssertEqual(windows.first?.usedPercent, 12)
    }

    /// 知らない種類は出さない。意味の分からない枠を数字付きで並べない。
    func testIgnoresLimitKindsItDoesNotUnderstand() throws {
        let json = """
        {"limits":[{"group":"monthly","kind":"monthly_all","percent":3,"scope":null,
                    "resets_at":"2026-11-30T08:00:00+00:00"}]}
        """
        XCTAssertTrue(ClaudeCollector.windows(from: try XCTUnwrap(payload(json).limits)).isEmpty)
    }

    /// 範囲外・欠落・読めない時刻は落とし、残った枠だけを通すこと。
    /// 日付の検査は取得側（`validated`）が持つので、実際の経路どおりそこを通して確かめる。
    func testDropsOutOfRangeAndUnparsableLimitsButKeepsTheRest() throws {
        let json = """
        {"limits":[{"kind":"session","percent":140,"scope":null,"resets_at":null},
                   {"kind":"weekly_all","percent":null,"scope":null,"resets_at":null},
                   {"kind":"weekly_scoped","percent":4,"scope":null,"resets_at":"not a date"},
                   {"kind":"weekly_all","percent":9,"scope":null,
                    "resets_at":"2026-11-07T08:00:00+00:00"}]}
        """
        let kept = try XCTUnwrap(ClaudeUsageAPI.validated(try payload(json), now: Date()))
        let windows = ClaudeCollector.windows(from: try XCTUnwrap(kept.limits))
        XCTAssertEqual(windows.map(\.id), ["seven_day"])
        XCTAssertEqual(windows.first?.usedPercent, 9)
    }

    /// すべて無効なら、枠なしとして扱って従来の経路へ落とすこと。
    func testTreatsAnEntirelyInvalidResponseAsNoData() throws {
        let json = """
        {"limits":[{"kind":"session","percent":140,"scope":null,"resets_at":null}]}
        """
        XCTAssertNil(ClaudeUsageAPI.validated(try payload(json), now: Date()))
    }

    /// 旧来の応答（limitsなし）でもこれまでどおり読めること。
    func testStillReadsResponsesWithoutTheLimitsArray() throws {
        let json = """
        {"five_hour":{"utilization":22,"resets_at":"2026-10-31T11:50:00+00:00"},
         "seven_day":{"utilization":7,"resets_at":"2026-11-07T08:00:00+00:00"},
         "seven_day_opus":{"utilization":3,"resets_at":"2026-11-07T08:00:00+00:00"}}
        """
        let decoded = try XCTUnwrap(ClaudeUsageAPI.validated(try payload(json), now: Date()))
        XCTAssertNil(decoded.limits)
        XCTAssertEqual(decoded.five_hour?.utilization, 22)
        XCTAssertEqual(decoded.seven_day_opus?.utilization, 3)
    }
}
