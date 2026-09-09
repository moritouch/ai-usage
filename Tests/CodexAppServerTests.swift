import Foundation
import XCTest

final class CodexAppServerTests: XCTestCase {
    /// `codex app-server` が実際に返す形。ログ側とはキーの綴りが違う。
    private let liveResponse = """
    {"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,\
    "primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1789435319},\
    "secondary":null,"planType":"pro"},\
    "rateLimitsByLimitId":{\
    "codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark",\
    "primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1788921729},\
    "secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1789508529},\
    "planType":"pro"},\
    "codex":{"limitId":"codex","limitName":null,\
    "primary":{"usedPercent":36,"windowDurationMins":10080,"resetsAt":1789435319},\
    "secondary":null,"planType":"pro"}},\
    "accountId":"redacted"}}
    """

    private func buckets(_ line: String) -> [CodexCollector.RateLimits]? {
        CodexAppServer.buckets(fromResponseLine: Data(line.utf8))
    }

    func testReadsEveryBucketFromTheLiveShape() throws {
        let buckets = try XCTUnwrap(buckets(liveResponse))
        XCTAssertEqual(Set(buckets.compactMap(\.limit_id)), ["codex", "codex_bengalfox"])

        let plan = try XCTUnwrap(buckets.first { $0.limit_id == "codex" })
        XCTAssertEqual(plan.primary?.used_percent, 36)
        XCTAssertEqual(plan.primary?.window_minutes, 10_080)
        XCTAssertEqual(plan.plan_type, "pro")
        // Proのプラン枠に5hは無い。null を落とさず null のまま渡せていること。
        XCTAssertNil(plan.secondary)

        let model = try XCTUnwrap(buckets.first { $0.limit_id == "codex_bengalfox" })
        XCTAssertEqual(model.limit_name, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(model.secondary?.window_minutes, 10_080)
    }

    /// プラン枠が週次だけなら、出る窓も週次だけ。存在しない5hを補ってはいけない。
    func testPlanBucketYieldsOnlyTheWeeklyWindow() throws {
        let buckets = try XCTUnwrap(buckets(liveResponse))
        let observations = buckets.map {
            CodexCollector.Observation(limits: $0, observedAt: Date())
        }
        let hit = try XCTUnwrap(CodexCollector.selectBucket(from: observations))
        XCTAssertEqual(hit.limits.limit_id, "codex")

        let windows = CodexCollector.usableWindows(of: hit.limits)
        XCTAssertEqual(windows.map(\.label), ["7d"])
        XCTAssertEqual(windows.first?.usedPercent, 36)
    }

    func testSkipsLinesThatAreNotTheAnsweredRequest() {
        XCTAssertNil(buckets(#"{"method":"remoteControl/status/changed","params":{}}"#))
        XCTAssertNil(buckets(#"{"id":1,"result":{"codexHome":"/Users/x/.codex"}}"#))
        XCTAssertNil(buckets("not json"))
    }

    /// 認証切れなどはエラーで返る。空で返して次の実行体へ譲る。
    func testErrorResponseYieldsNoBuckets() {
        XCTAssertEqual(
            buckets(#"{"error":{"code":-32600,"message":"Not initialized"},"id":2}"#)?.count,
            0
        )
    }

    func testLocatorRejectsCommandsThatDoNotExist() {
        XCTAssertNil(CLILocator.locate("ai-usage-command-that-does-not-exist"))
    }
}
