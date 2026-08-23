import Foundation
import XCTest

final class UsageModelsTests: XCTestCase {
    func testAutomaticHeadlinePrefersCurrentShortWindow() {
        let stale = agent(id: "stale", percent: 99, status: .stale, short: false)
        let current = agent(id: "current", percent: 35, status: .ok, short: true)
        let snapshot = UsageSnapshot(
            updatedAt: Date(), agents: [stale, current], preferredAgentID: nil
        )

        XCTAssertEqual(snapshot.headline?.agent.id, "current")
    }

    func testManualHeadlineHonorsPinnedAgent() {
        let first = agent(id: "first", percent: 20, status: .ok, short: true)
        let pinned = agent(id: "pinned", percent: 80, status: .ok, short: false)
        let snapshot = UsageSnapshot(
            updatedAt: Date(), agents: [first, pinned], preferredAgentID: "pinned"
        )

        XCTAssertEqual(snapshot.headline?.agent.id, "pinned")
    }

    func testUsageWindowClampsPercentAndRejectsExtremeDate() {
        let window = UsageWindow(
            id: "test", label: "Test", usedPercent: 140,
            resetsAt: Date(timeIntervalSince1970: 1e100), windowSeconds: -1
        )

        XCTAssertEqual(window.usedPercent, 100)
        XCTAssertNil(window.resetsAt)
        XCTAssertNil(window.windowSeconds)
    }

    func testDurationTextDoesNotTrapForExtremeDate() {
        XCTAssertEqual(
            UsageWindow.durationText(until: Date(timeIntervalSince1970: 1e100)),
            "unknown"
        )
    }

    func testOldOKAgentBecomesStale() {
        var old = agent(id: "old", percent: 40, status: .ok, short: true)
        old.observedAt = Date().addingTimeInterval(-7 * 3_600)
        XCTAssertEqual(old.displayStatus, .stale)
    }

    func testFarFutureObservationIsNotFresh() {
        var future = agent(id: "future", percent: 40, status: .ok, short: true)
        future.observedAt = Date().addingTimeInterval(3_600)

        XCTAssertEqual(future.displayStatus, .stale)
    }

    func testDecodedPercentIsClamped() throws {
        let data = Data(
            #"{"id":"test","label":"Test","usedPercent":-20,"resetsAt":null,"windowSeconds":18000}"#.utf8
        )
        let window = try JSONDecoder().decode(UsageWindow.self, from: data)

        XCTAssertEqual(window.usedPercent, 0)
    }

    func testPlanLabelRemovesFormatCharactersAndBoundsLength() {
        XCTAssertEqual(PlanLabel.normalize("pro\u{200B}"), "Pro")
        XCTAssertNil(PlanLabel.normalize("\u{0000}\u{200B}"))
        XCTAssertEqual(PlanLabel.normalize(String(repeating: "a", count: 500))?.count, 128)
    }

    func testSelectedLanguageUsesMatchingCopy() {
        XCTAssertEqual(L10n.text("common.stale", language: .english), "Stale")
        XCTAssertEqual(L10n.text("common.stale", language: .japanese), "古い値")
        XCTAssertEqual(
            L10n.format("common.left.format", language: .japanese, "42%"),
            "残り 42%"
        )
        XCTAssertEqual(
            L10n.format(
                "menubar.summary.format",
                language: .english,
                "Codex", "7d", "56%", ""
            ),
            "Codex, 7d, 56% used"
        )
        XCTAssertEqual(
            L10n.format(
                "menubar.summary.format",
                language: .japanese,
                "Codex", "7d", "56%", "、古いデータ"
            ),
            "Codex、7d、使用済み56%、古いデータ"
        )
        XCTAssertEqual(
            L10n.windowLabel(
                UsageWindow(
                    id: "primary", label: "Usage", usedPercent: 1,
                    resetsAt: nil, windowSeconds: nil
                ),
                language: .japanese
            ),
            "使用量"
        )
    }

    func testSelectedLanguageKeepsCurrentRegion() {
        let currentRegion = Locale.autoupdatingCurrent.region?.identifier
        XCTAssertEqual(AppLanguage.english.locale.region?.identifier, currentRegion)
        XCTAssertEqual(AppLanguage.japanese.locale.region?.identifier, currentRegion)
        XCTAssertEqual(AppLanguage.english.locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(AppLanguage.japanese.locale.language.languageCode?.identifier, "ja")
    }

    private func agent(
        id: String, percent: Double, status: AgentStatus, short: Bool
    ) -> AgentUsage {
        AgentUsage(
            id: id,
            name: id,
            plan: nil,
            windows: [
                UsageWindow(
                    id: "window", label: short ? "5h" : "7d",
                    usedPercent: percent,
                    resetsAt: Date().addingTimeInterval(3_600),
                    windowSeconds: short ? 5 * 3_600 : 7 * 86_400
                )
            ],
            observedAt: Date(),
            source: "test",
            status: status,
            note: nil
        )
    }
}
