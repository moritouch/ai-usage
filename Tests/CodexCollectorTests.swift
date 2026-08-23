import Foundation
import XCTest

final class CodexCollectorTests: XCTestCase {
    func testFindRateLimitsSkipsNonObjectValues() {
        let invalidValues: [Any] = [
            NSNull(),
            "invalid",
            42,
            true,
            ["unexpected"],
            [String: Any](),
        ]

        for value in invalidValues {
            XCTAssertNil(
                CodexCollector.findRateLimits(in: ["rate_limits": value]),
                "Expected \(type(of: value)) to be ignored"
            )
        }
    }

    func testFindRateLimitsContinuesAfterNullValue() throws {
        let root: [String: Any] = [
            "rate_limits": NSNull(),
            "nested": [
                "rate_limits": [
                    "primary": [
                        "used_percent": 42.0,
                        "window_minutes": 10_080,
                    ],
                    "plan_type": "pro",
                ],
            ],
        ]

        let limits = try XCTUnwrap(CodexCollector.findRateLimits(in: root))
        XCTAssertEqual(try XCTUnwrap(limits.primary?.used_percent), 42.0, accuracy: 0.001)
        XCTAssertEqual(limits.primary?.window_minutes, 10_080)
        XCTAssertEqual(limits.plan_type, "pro")
    }

    func testScanTailFallsBackPastMalformedAndInvalidLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let validLine = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":56,"window_minutes":10080},"plan_type":"pro"}}}"#
        let malformedLine = "{\"rate_limits\":"
        let invalidLiterals = [
            "null",
            "\"invalid\"",
            "42",
            "true",
            "[\"unexpected\"]",
            "{}",
        ]

        for (index, literal) in invalidLiterals.enumerated() {
            let logURL = directory.appendingPathComponent("rollout-test-\(index).jsonl")
            let invalidLine = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":\(literal)}}"
            try Data([validLine, invalidLine, malformedLine].joined(separator: "\n").utf8)
                .write(to: logURL, options: .atomic)

            let hit = try XCTUnwrap(
                CodexCollector.scanTail(of: logURL),
                "Expected fallback after \(literal)"
            )
            XCTAssertEqual(
                try XCTUnwrap(hit.limits.primary?.used_percent),
                56.0,
                accuracy: 0.001
            )
            XCTAssertEqual(hit.limits.primary?.window_minutes, 10_080)
            XCTAssertEqual(hit.limits.plan_type, "pro")
        }
    }
}
