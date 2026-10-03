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

    func testStaleWindowsAreRemovedAfterTheirResetDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = agent(id: "codex", percent: 40, status: .stale, short: true)
        stale.observedAt = now.addingTimeInterval(-60 * 86_400)
        stale.windows[0].resetsAt = now.addingTimeInterval(-1)

        let expired = stale.expiringStaleData(at: now)

        XCTAssertTrue(expired.windows.isEmpty)
        XCTAssertEqual(expired.status, .unavailable)
        XCTAssertEqual(
            expired.note,
            "Codex usage data expired; complete a Codex response, then check again"
        )
    }

    func testExpiringStaleDataKeepsTheCollectorsSpecificNote() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = agent(id: "claude-code", percent: 40, status: .stale, short: true)
        stale.observedAt = now.addingTimeInterval(-60 * 86_400)
        stale.windows[0].resetsAt = now.addingTimeInterval(-1)
        stale.note = "Claude usage needs a terminal Claude Code sign-in; run claude in Terminal, then check again"

        let expired = stale.expiringStaleData(at: now)

        XCTAssertTrue(expired.windows.isEmpty)
        XCTAssertEqual(expired.status, .unavailable)
        XCTAssertEqual(
            expired.note,
            "Claude usage needs a terminal Claude Code sign-in; run claude in Terminal, then check again"
        )
    }

    func testFreshObservationDoesNotKeepAWindowAfterItsResetDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var fresh = agent(id: "codex", percent: 40, status: .ok, short: true)
        fresh.observedAt = now.addingTimeInterval(-2 * 3_600)
        fresh.windows[0].resetsAt = now.addingTimeInterval(-3_600)

        let expired = fresh.expiringStaleData(at: now)

        XCTAssertTrue(expired.windows.isEmpty)
        XCTAssertEqual(expired.status, .unavailable)
    }

    func testWindowExpiresAtItsExactResetDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var fresh = agent(id: "codex", percent: 40, status: .ok, short: true)
        fresh.observedAt = now.addingTimeInterval(-60)
        fresh.windows[0].resetsAt = now

        XCTAssertTrue(fresh.expiringStaleData(at: now).windows.isEmpty)
    }

    func testOnlyWindowsWhoseResetDatesPassedAreRemoved() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = agent(id: "claude-code", percent: 40, status: .stale, short: true)
        stale.observedAt = now.addingTimeInterval(-7 * 3_600)
        stale.windows[0].resetsAt = now.addingTimeInterval(-1)
        stale.windows.append(
            UsageWindow(
                id: "future", label: "7d", usedPercent: 20,
                resetsAt: now.addingTimeInterval(3_600), windowSeconds: 7 * 86_400
            )
        )

        let retained = stale.expiringStaleData(at: now)

        XCTAssertEqual(retained.windows.map(\.id), ["future"])
        XCTAssertEqual(retained.status, .stale)
    }

    func testStaleWindowRemainsVisibleUntilItsResetDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = agent(id: "codex", percent: 40, status: .stale, short: true)
        stale.observedAt = now.addingTimeInterval(-7 * 3_600)
        stale.windows[0].resetsAt = now.addingTimeInterval(60)

        XCTAssertEqual(stale.expiringStaleData(at: now).windows, stale.windows)
    }

    func testStaleWindowWithoutResetHasBoundedRetention() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = agent(id: "unknown", percent: 40, status: .stale, short: true)
        stale.observedAt = now.addingTimeInterval(-31 * 86_400)
        stale.windows[0].resetsAt = nil

        XCTAssertTrue(stale.expiringStaleData(at: now).windows.isEmpty)
    }

    func testUnknownResetIsRetainedThroughThirtyDayBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = agent(id: "unknown", percent: 40, status: .stale, short: true)
        stale.observedAt = now.addingTimeInterval(-AgentUsage.maximumStaleRetention)
        stale.windows[0].resetsAt = nil

        XCTAssertEqual(stale.expiringStaleData(at: now).windows, stale.windows)

        stale.observedAt = stale.observedAt?.addingTimeInterval(-1)
        XCTAssertTrue(stale.expiringStaleData(at: now).windows.isEmpty)
    }

    func testMissingObservationExpiresUnknownResetWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = agent(id: "unknown", percent: 40, status: .ok, short: true)
        stale.observedAt = nil
        stale.windows[0].resetsAt = nil

        XCTAssertEqual(stale.displayStatus(at: now), .stale)
        XCTAssertTrue(stale.expiringStaleData(at: now).windows.isEmpty)
    }

    func testDecodedPercentIsClamped() throws {
        let data = Data(
            #"{"id":"test","label":"Test","usedPercent":-20,"resetsAt":null,"windowSeconds":18000}"#.utf8
        )
        let window = try JSONDecoder().decode(UsageWindow.self, from: data)

        XCTAssertEqual(window.usedPercent, 0)
    }

    /// claude.ai 経路ではプランが応答に無く、ログイン記録の `claude_pro` から拾う。
    /// 接頭辞を落として既知の等級へ寄せられることを固定する。
    func testPlanLabelNormalizesTheLocalAccountOrganizationType() {
        XCTAssertEqual(PlanLabel.normalize("claude_pro"), "Pro")
        XCTAssertEqual(PlanLabel.normalize("claude_max"), "Max")
        XCTAssertEqual(PlanLabel.normalize("claude_team"), "Team")
    }

    /// ProはPro 100 / Pro 200 / Pro 500へ分かれた。どの等級かが分かること。
    /// 対応はChatGPTアプリ内の表示文言に合わせている。
    func testPlanLabelNamesTheOpenAIProTiers() {
        XCTAssertEqual(PlanLabel.normalize("prolite", vendor: .openAI), "Pro 100")
        XCTAssertEqual(PlanLabel.normalize("pro", vendor: .openAI), "Pro 200")
        XCTAssertEqual(PlanLabel.normalize("promax", vendor: .openAI), "Pro 500")
        XCTAssertEqual(PlanLabel.normalize("plus", vendor: .openAI), "Plus")
        XCTAssertEqual(PlanLabel.normalize("go", vendor: .openAI), "Go")
    }

    /// 等級はOpenAIの話。同じ識別子で来るClaudeのPro/Maxを巻き込まないこと。
    func testPlanLabelKeepsOtherVendorsOutOfTheOpenAITiers() {
        XCTAssertEqual(PlanLabel.normalize("claude_pro"), "Pro")
        XCTAssertEqual(PlanLabel.normalize("pro"), "Pro")
        XCTAssertEqual(PlanLabel.normalize("team"), "Team")
        XCTAssertEqual(PlanLabel.normalize("max20x"), "Max")
    }

    /// Businessは標準シートとプレミアムシートで使える量が違う。見分けられること。
    func testPlanLabelDistinguishesTheBusinessPremiumSeat() {
        XCTAssertEqual(
            PlanLabel.normalize("self_serve_business_prolite", vendor: .openAI), "Business Premium"
        )
        XCTAssertEqual(
            PlanLabel.normalize("self_serve_business_usage_based", vendor: .openAI),
            "Business Usage-based"
        )
        XCTAssertEqual(PlanLabel.normalize("team", vendor: .openAI), "Business")
        XCTAssertEqual(PlanLabel.normalize("business", vendor: .openAI), "Business")
    }

    /// 企業向けと教育向けは種類が多い。どれも短い表記にそろえる。
    func testPlanLabelShortensEnterpriseAndEducationIdentifiers() {
        for raw in ["ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise"] {
            XCTAssertEqual(PlanLabel.normalize(raw, vendor: .openAI), "Enterprise", raw)
        }
        XCTAssertEqual(PlanLabel.normalize("edu_plus", vendor: .openAI), "Edu Plus")
        XCTAssertEqual(PlanLabel.normalize("edu_pro", vendor: .openAI), "Edu Pro")
    }

    func testPlanLabelRemovesFormatCharactersAndBoundsLength() {
        XCTAssertEqual(PlanLabel.normalize("pro\u{200B}"), "Pro")
        XCTAssertNil(PlanLabel.normalize("\u{0000}\u{200B}"))
        XCTAssertEqual(PlanLabel.normalize(String(repeating: "a", count: 500))?.count, 128)
    }

    func testSelectedLanguageUsesMatchingCopy() {
        XCTAssertEqual(L10n.text("common.stale", language: .english), "Stale")
        XCTAssertEqual(L10n.text("common.stale", language: .japanese), "Stale")
        XCTAssertEqual(L10n.text("common.quit", language: .japanese), "Quit")
        XCTAssertEqual(
            L10n.format("popover.checked.format", language: .japanese, "9:41:28"),
            "Checked 9:41:28"
        )
        XCTAssertEqual(
            L10n.text("popover.notChecked", language: .japanese),
            "Not checked yet"
        )
        XCTAssertEqual(
            L10n.format(
                "settings.staleStatus.format",
                language: .japanese,
                "usage API", "6時間前"
            ),
            "Stale · usage API — 6時間前"
        )
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

    /// 請求期間の枠は複数のエージェントが持つ。どれも日本語で出す。
    func testEveryPeriodWindowIsLocalized() {
        for id in ["grok_period", "grokbot_period", "cursor_period"] {
            XCTAssertEqual(
                L10n.windowLabel(
                    UsageWindow(
                        id: id, label: "Period", usedPercent: 1,
                        resetsAt: nil, windowSeconds: nil
                    ),
                    language: .japanese
                ),
                "期間",
                id
            )
        }
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
