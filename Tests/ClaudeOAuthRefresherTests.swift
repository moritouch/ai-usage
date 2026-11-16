import Foundation
import XCTest

final class ClaudeOAuthRefresherTests: XCTestCase {
    func testOAuthErrorCodeAcceptsBothAnthropicShapes() {
        XCTAssertEqual(
            ClaudeOAuthRefresher.oauthErrorCode(
                in: Data(#"{"error":"invalid_scope"}"#.utf8)
            ),
            "invalid_scope"
        )
        XCTAssertEqual(
            ClaudeOAuthRefresher.oauthErrorCode(
                in: Data(#"{"error":{"type":"invalid_scope"}}"#.utf8)
            ),
            "invalid_scope"
        )
    }

    func testOAuthErrorCodeRejectsUnrelatedShapes() {
        XCTAssertNil(ClaudeOAuthRefresher.oauthErrorCode(
            in: Data(#"{"type":"invalid_scope"}"#.utf8)
        ))
        XCTAssertNil(ClaudeOAuthRefresher.oauthErrorCode(in: Data("[]".utf8)))
        XCTAssertNil(ClaudeOAuthRefresher.oauthErrorCode(in: Data("not-json".utf8)))
    }

    func testExpandedDefaultScopesKeepsOnlySupportedExpansionScopes() {
        let result = ClaudeOAuthRefresher.expandedDefaultScopes(from: [
            "user:plugins",
            "custom:unsupported",
            "user:projects:read",
            "user:inference",
            "user:plugins",
        ])

        XCTAssertEqual(result, [
            "user:profile",
            "user:inference",
            "user:sessions:claude_code",
            "user:mcp_servers",
            "user:file_upload",
            "user:plugins",
            "user:projects:read",
        ])
    }

    func test401ForceRefreshDoesNotReuseTheRejectedAccessToken() {
        XCTAssertFalse(ClaudeOAuthRefresher.shouldReuseCurrentAccessToken(
            "same-token",
            originalAccessToken: "same-token",
            force: true
        ))
        XCTAssertTrue(ClaudeOAuthRefresher.shouldReuseCurrentAccessToken(
            "same-token",
            originalAccessToken: "same-token",
            force: false
        ))
        XCTAssertTrue(ClaudeOAuthRefresher.shouldReuseCurrentAccessToken(
            "newer-sibling-token",
            originalAccessToken: "rejected-token",
            force: true
        ))
    }

    func testScopePersistenceUsesTheRequestThatActuallySucceeded() {
        let storedFallback = ["user:profile", "user:inference"]

        XCTAssertEqual(
            ClaudeOAuthRefresher.scopesForPersistence(
                responseScopes: nil,
                effectiveRequestScopes: storedFallback
            ),
            storedFallback
        )
        XCTAssertEqual(
            ClaudeOAuthRefresher.scopesForPersistence(
                responseScopes: ["not a valid scope"],
                effectiveRequestScopes: storedFallback
            ),
            storedFallback
        )
    }

    func testRefreshLockUsesEmptyDirectoriesAndRemovesThemOnRelease() async throws {
        let paths = try makeLockFixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let lock = await ClaudeOAuthRefreshLock.acquire(
            directory: paths.claude,
            attempts: 1,
            retryMilliseconds: 1...1
        )
        let acquired = try XCTUnwrap(lock)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: paths.current.path
        ), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: paths.legacy.path
        ), [])

        await acquired.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacy.path))
    }

    func testRefreshLockRecoversOnlyEmptyStaleDirectories() async throws {
        let paths = try makeLockFixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.legacy, withIntermediateDirectories: true)
        let stale = Date().addingTimeInterval(-120)
        try FileManager.default.setAttributes(
            [.modificationDate: stale], ofItemAtPath: paths.current.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: stale], ofItemAtPath: paths.legacy.path
        )

        let lock = await ClaudeOAuthRefreshLock.acquire(
            directory: paths.claude,
            attempts: 1,
            retryMilliseconds: 1...1
        )
        let acquired = try XCTUnwrap(lock)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: paths.current.path
        ), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: paths.legacy.path
        ), [])
        await acquired.release()
    }

    func testRefreshLockDoesNotDeleteNonemptyStaleDirectory() async throws {
        let paths = try makeLockFixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.current, withIntermediateDirectories: true)
        let owner = paths.current.appendingPathComponent("owner")
        try Data("someone-else".utf8).write(to: owner)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-120)],
            ofItemAtPath: paths.current.path
        )

        let lock = await ClaudeOAuthRefreshLock.acquire(
            directory: paths.claude,
            attempts: 1,
            retryMilliseconds: 1...1
        )

        XCTAssertNil(lock)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owner.path))
    }

    func testRefreshLockDetectsPathReplacementAndLeavesReplacementAlone() async throws {
        let paths = try makeLockFixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let acquired = await ClaudeOAuthRefreshLock.acquire(
            directory: paths.claude,
            attempts: 1,
            retryMilliseconds: 1...1
        )
        let lock = try XCTUnwrap(acquired)
        let moved = paths.root.appendingPathComponent("moved-current-lock")
        try FileManager.default.moveItem(at: paths.current, to: moved)
        try FileManager.default.createDirectory(at: paths.current, withIntermediateDirectories: true)

        XCTAssertFalse(lock.isValid)
        await lock.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.current.path))
    }

    private func makeLockFixture() throws -> (
        root: URL, claude: URL, current: URL, legacy: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let claude = root.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        return (
            root,
            claude,
            claude.appendingPathComponent(".oauth_refresh.lock", isDirectory: true),
            URL(fileURLWithPath: claude.path + ".lock", isDirectory: true)
        )
    }
}

/// 使用量を読むまでの手順のうち、期限切れと更新の扱い。Keychainと通信は差し替える。
/// ターミナル版の有無で更新を止めると、使わない日は期限切れのまま止まる（0.1.29まで）。
final class ClaudeUsageAPIRefreshTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var refreshes: [Bool] = []
        private var sessionKeys: [Bool] = []
        private var performed: [String] = []

        func refresh(force: Bool) { lock.withLock { refreshes.append(force) } }
        func sessionKey(reportingFailure: Bool) { lock.withLock { sessionKeys.append(reportingFailure) } }
        func perform(_ accessToken: String) { lock.withLock { performed.append(accessToken) } }
        var snapshot: (refreshes: [Bool], sessionKeys: [Bool], performed: [String]) {
            lock.withLock { (refreshes, sessionKeys, performed) }
        }
    }

    private static func credential(_ accessToken: String) -> ClaudeKeychain.OAuthCredential {
        ClaudeKeychain.OAuthCredential(
            accessToken: accessToken,
            refreshToken: "refresh-\(accessToken)",
            expiresAt: Date(),
            scopes: [],
            subscriptionType: "team",
            rateLimitTier: nil,
            clientID: nil
        )
    }

    private static let payload = ClaudeUsageAPI.Payload(
        five_hour: nil,
        seven_day: ClaudeUsageAPI.Window(utilization: 3, resets_at: nil),
        seven_day_opus: nil,
        limits: nil
    )

    private func dependencies(
        _ calls: Calls,
        refresh: ClaudeOAuthRefresher.Outcome,
        sessionKey: ClaudeUsageAPI.AttemptOutcome? = nil
    ) -> ClaudeUsageAPI.Dependencies {
        ClaudeUsageAPI.Dependencies(
            credentialState: { .refreshable(Self.credential("expired")) },
            refresh: { _, force in
                calls.refresh(force: force)
                return refresh
            },
            sessionKey: { reportingFailure in
                calls.sessionKey(reportingFailure: reportingFailure)
                return sessionKey
            },
            hasSignedInAccount: { true },
            performUsage: { credential in
                calls.perform(credential.accessToken)
                return .success(Self.payload, plan: "Team")
            }
        )
    }

    private func label(_ outcome: ClaudeUsageAPI.AttemptOutcome) -> String {
        switch outcome {
        case .success: return "success"
        case .refreshBusy: return "busy"
        case .credentialExpired: return "expired"
        case .credentialUnavailable: return "unavailable"
        case .failed: return "failed"
        default: return "other"
        }
    }

    /// 期限切れなら、ほかの条件を見ずに更新してから新しいtokenで読む。
    func testExpiredCredentialIsRenewedBeforeReadingUsage() async {
        let calls = Calls()
        let outcome = await ClaudeUsageAPI.prepareCredentialAndPerform(
            using: dependencies(calls, refresh: .credential(Self.credential("renewed")))
        )

        XCTAssertEqual(label(outcome), "success")
        XCTAssertEqual(calls.snapshot.refreshes, [false])
        XCTAssertEqual(calls.snapshot.performed, ["renewed"])
        XCTAssertEqual(calls.snapshot.sessionKeys, [])
    }

    /// 更新を拒否された、またはKeychainへ書けなかった場合は、session keyを先に試す。
    func testFailedRenewalFallsBackToTheSessionKey() async {
        for (refresh, withoutKey) in [
            (ClaudeOAuthRefresher.Outcome.unauthorized, "expired"),
            (.keychainUnavailable, "unavailable"),
        ] {
            let withKey = Calls()
            let rescued = await ClaudeUsageAPI.prepareCredentialAndPerform(
                using: dependencies(withKey, refresh: refresh, sessionKey: .success(Self.payload, plan: nil))
            )
            XCTAssertEqual(label(rescued), "success")
            XCTAssertEqual(withKey.snapshot.sessionKeys, [false])

            let noKey = Calls()
            let failed = await ClaudeUsageAPI.prepareCredentialAndPerform(
                using: dependencies(noKey, refresh: refresh)
            )
            XCTAssertEqual(label(failed), withoutKey)
            XCTAssertEqual(noKey.snapshot.performed, [])
        }
    }

    /// ターミナル版が更新中でlockを取れないのは、通信の失敗ではない。
    func testBusyRefreshLockIsNotReportedAsAFailure() async {
        let calls = Calls()
        let outcome = await ClaudeUsageAPI.prepareCredentialAndPerform(
            using: dependencies(calls, refresh: .temporarilyUnavailable)
        )

        XCTAssertEqual(label(outcome), "busy")
        XCTAssertEqual(calls.snapshot.performed, [])
    }
}
