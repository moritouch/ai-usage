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
