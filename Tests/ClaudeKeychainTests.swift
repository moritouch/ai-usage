import Foundation
import Security
import XCTest

final class ClaudeKeychainTests: XCTestCase {
    func testKeychainQueryPinsTheClaudeServiceAndMacAccount() {
        let query = ClaudeKeychain.keychainQuery(accountName: "fixture-user")

        XCTAssertEqual(
            query[kSecClass as String] as? String,
            kSecClassGenericPassword as String
        )
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            "Claude Code-credentials"
        )
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String,
            "fixture-user"
        )
    }

    func testKeychainCancellationAndAccessDenialAreNotRetried() {
        XCTAssertFalse(ClaudeKeychain.shouldRetryReadFailure(errSecItemNotFound))
        XCTAssertFalse(ClaudeKeychain.shouldRetryReadFailure(errSecAuthFailed))
        XCTAssertFalse(ClaudeKeychain.shouldRetryReadFailure(errSecInteractionNotAllowed))
        XCTAssertFalse(ClaudeKeychain.shouldRetryReadFailure(errSecUserCanceled))
        XCTAssertTrue(ClaudeKeychain.shouldRetryReadFailure(errSecNotAvailable))
    }

    func testPayloadShapeSeparatesAnMcpOnlyItemFromMalformedData() throws {
        // デスクトップ版Claudeだけを使うと、同じKeychain項目に mcpOAuth しか入らない。
        // これを malformed と同じ扱いにすると案内が「再ログイン」になり、実際に必要な
        // ターミナルログインへ辿り着けない。
        let mcpOnly = try JSONSerialization.data(
            withJSONObject: ["mcpOAuth": ["server": ["accessToken": "value"]]]
        )
        XCTAssertEqual(ClaudeKeychain.payloadShape(mcpOnly), .notLinked)

        let linked = try JSONSerialization.data(
            withJSONObject: [
                "claudeAiOauth": ["accessToken": "value"],
                "mcpOAuth": ["server": ["accessToken": "value"]],
            ]
        )
        XCTAssertEqual(ClaudeKeychain.payloadShape(linked), .usable)

        XCTAssertEqual(ClaudeKeychain.payloadShape(Data("not json".utf8)), .malformed)

        let wrongType = try JSONSerialization.data(
            withJSONObject: ["claudeAiOauth": "unexpected"]
        )
        XCTAssertEqual(ClaudeKeychain.payloadShape(wrongType), .malformed)
    }

    func testCredentialMergeRotatesTokensAndPreservesUnknownFields() throws {
        let source: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "expiresAt": 1_700_000_000_000,
                "scopes": ["user:profile"],
                "subscriptionType": "pro",
                "clientId": "future-client",
                "futureField": ["enabled": true],
            ],
            "mcpOAuth": ["server": ["accessToken": "untouched"]],
            "futureRoot": "untouched",
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)

        let updated = try XCTUnwrap(ClaudeKeychain.updatedCredentialData(
            data,
            expectedAccessToken: "old-access",
            expectedRefreshToken: "old-refresh",
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: expiration,
            scopes: ["user:profile", "user:inference"]
        ))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: updated) as? [String: Any]
        )
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(oauth["expiresAt"] as? Double, 1_800_000_000_000)
        XCTAssertEqual(
            oauth["scopes"] as? [String],
            ["user:profile", "user:inference"]
        )
        XCTAssertEqual(oauth["subscriptionType"] as? String, "pro")
        XCTAssertEqual(oauth["clientId"] as? String, "future-client")
        XCTAssertEqual(
            (oauth["futureField"] as? [String: Any])?["enabled"] as? Bool,
            true
        )
        XCTAssertEqual(root["futureRoot"] as? String, "untouched")
        let mcp = try XCTUnwrap(root["mcpOAuth"] as? [String: Any])
        let server = try XCTUnwrap(mcp["server"] as? [String: Any])
        XCTAssertEqual(server["accessToken"] as? String, "untouched")
    }

    func testCredentialMergeRejectsConcurrentTokenChange() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "newer-access",
                "refreshToken": "newer-refresh",
            ],
        ])

        XCTAssertNil(ClaudeKeychain.updatedCredentialData(
            data,
            expectedAccessToken: "old-access",
            expectedRefreshToken: "old-refresh",
            accessToken: "ours-access",
            refreshToken: "ours-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    func testCredentialMergeSupportsPreviouslyMissingRefreshToken() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "old-access"],
            "sibling": 42,
        ])

        let updated = try XCTUnwrap(ClaudeKeychain.updatedCredentialData(
            data,
            expectedAccessToken: "old-access",
            expectedRefreshToken: nil,
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: updated) as? [String: Any]
        )
        XCTAssertEqual(root["sibling"] as? Int, 42)
    }
}
