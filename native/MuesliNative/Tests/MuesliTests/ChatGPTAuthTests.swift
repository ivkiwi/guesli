import CryptoKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("ChatGPT OAuth", .muesliHermeticSupport)
struct ChatGPTAuthTests {

    // MARK: - PKCE

    @Test("PKCE verifier is base64url with no padding")
    @MainActor
    func pkceVerifierFormat() {
        let auth = ChatGPTAuthManager.shared
        let (verifier, _) = auth.generatePKCE()
        #expect(!verifier.isEmpty)
        #expect(!verifier.contains("+"))
        #expect(!verifier.contains("/"))
        #expect(!verifier.contains("="))
    }

    @Test("PKCE challenge is SHA256 of verifier")
    @MainActor
    func pkceChallengeIsCorrect() {
        let auth = ChatGPTAuthManager.shared
        let (verifier, challenge) = auth.generatePKCE()

        // Manually compute expected challenge
        let expectedData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let expected = expectedData.base64URLEncoded()
        #expect(challenge == expected)
    }

    @Test("PKCE generates unique values each time")
    @MainActor
    func pkceUniqueness() {
        let auth = ChatGPTAuthManager.shared
        let (v1, _) = auth.generatePKCE()
        let (v2, _) = auth.generatePKCE()
        #expect(v1 != v2)
    }

    // MARK: - State

    @Test("state is at least 8 characters (OpenAI minimum)")
    @MainActor
    func stateMinLength() {
        let auth = ChatGPTAuthManager.shared
        let state = auth.generateState()
        #expect(state.count >= 8)
    }

    // MARK: - Authorization URL

    @Test("authorization URL contains all required OAuth parameters")
    @MainActor
    func authURLContainsRequiredParams() {
        let auth = ChatGPTAuthManager.shared
        let url = auth.buildAuthorizationURL(codeChallenge: "test_challenge", state: "test_state")
        #expect(url != nil)

        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        let params = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })

        #expect(params["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(params["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(params["response_type"] == "code")
        #expect(params["scope"] == "openid profile email offline_access")
        #expect(params["state"] == "test_state")
        #expect(params["code_challenge"] == "test_challenge")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["id_token_add_organizations"] == "true")
        #expect(params["codex_cli_simplified_flow"] == "true")
        #expect(params["originator"] == "opencode")
    }

    @Test("authorization URL points to auth.openai.com")
    @MainActor
    func authURLHost() {
        let auth = ChatGPTAuthManager.shared
        let url = auth.buildAuthorizationURL(codeChallenge: "c", state: "s")!
        #expect(url.host == "auth.openai.com")
        #expect(url.path == "/oauth/authorize")
        #expect(url.scheme == "https")
    }

    // MARK: - Callback Code Extraction

    @Test("extracts code from standard OAuth callback")
    @MainActor
    func extractCodeStandard() {
        let auth = ChatGPTAuthManager.shared
        let request = "GET /auth/callback?code=abc123&state=xyz HTTP/1.1\r\nHost: localhost:1455\r\n\r\n"
        #expect(auth.extractCode(from: request) == "abc123")
    }

    @Test("extracts code with URL-encoded characters")
    @MainActor
    func extractCodeEncoded() {
        let auth = ChatGPTAuthManager.shared
        let request = "GET /auth/callback?code=abc%3D123&state=s HTTP/1.1\r\n\r\n"
        #expect(auth.extractCode(from: request) == "abc=123")
    }

    @Test("returns nil when code param is missing")
    @MainActor
    func extractCodeMissing() {
        let auth = ChatGPTAuthManager.shared
        let request = "GET /auth/callback?error=access_denied&state=s HTTP/1.1\r\n\r\n"
        #expect(auth.extractCode(from: request) == nil)
    }

    @Test("returns nil for empty request")
    @MainActor
    func extractCodeEmpty() {
        let auth = ChatGPTAuthManager.shared
        #expect(auth.extractCode(from: "") == nil)
    }

    @Test("returns nil for malformed request")
    @MainActor
    func extractCodeMalformed() {
        let auth = ChatGPTAuthManager.shared
        #expect(auth.extractCode(from: "garbage data") == nil)
    }

    @Test("handles LF-only line endings")
    @MainActor
    func extractCodeLFOnly() {
        let auth = ChatGPTAuthManager.shared
        let request = "GET /auth/callback?code=mycode&state=s HTTP/1.1\nHost: localhost\n\n"
        #expect(auth.extractCode(from: request) == "mycode")
    }

    // MARK: - JWT Account ID Extraction

    @Test("extracts chatgpt_account_id from top-level claim")
    @MainActor
    func jwtTopLevelClaim() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"chatgpt_account_id": "acct_123", "sub": "user"}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "acct_123")
    }

    @Test("extracts chatgpt_account_id from nested auth claim")
    @MainActor
    func jwtNestedClaim() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"https://api.openai.com/auth": {"chatgpt_account_id": "acct_456"}, "sub": "user"}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "acct_456")
    }

    @Test("falls back to organizations[0].id")
    @MainActor
    func jwtOrgFallback() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"organizations": [{"id": "org_789"}], "sub": "user"}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "org_789")
    }

    @Test("returns empty string for JWT without account claims")
    @MainActor
    func jwtNoClaims() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"sub": "user", "iat": 1234567890}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "")
    }

    @Test("returns empty string for invalid JWT")
    @MainActor
    func jwtInvalid() {
        let auth = ChatGPTAuthManager.shared
        #expect(auth.extractAccountId(from: "not.a.jwt") == "")
        #expect(auth.extractAccountId(from: "") == "")
        #expect(auth.extractAccountId(from: "single_segment") == "")
    }

    @Test("top-level chatgpt_account_id takes priority over nested")
    @MainActor
    func jwtClaimPriority() {
        let auth = ChatGPTAuthManager.shared
        let payload = #"{"chatgpt_account_id": "top", "https://api.openai.com/auth": {"chatgpt_account_id": "nested"}, "organizations": [{"id": "org"}]}"#
        let jwt = makeJWT(payload: payload)
        #expect(auth.extractAccountId(from: jwt) == "top")
    }

    // MARK: - Base64URL

    @Test("base64URL encoding removes padding and substitutes characters")
    func base64URLEncoding() {
        // Bytes that produce + and / in standard base64
        let data = Data([0xFB, 0xFF, 0xFE])
        let encoded = data.base64URLEncoded()
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test("base64URL encoding of empty data is empty string")
    func base64URLEmpty() {
        #expect(Data().base64URLEncoded() == "")
    }

    @Test("token file permissions are tightened to owner read-write")
    func tokenFilePermissionsAreTightened() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatgpt-auth-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try ChatGPTAuthManager.secureTokenFilePermissions(at: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("token store saves primary and backup with owner-only permissions")
    func tokenStoreSaveLoadRoundTripWithBackup() throws {
        let root = try makeTokenTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = TestLogSink()
        let store = makeTokenStore(root: root, logs: logs)

        try store.save(Self.sampleTokens, reason: "save")
        let loaded = try #require(store.load())

        #expect(loaded["access_token"] == "access")
        #expect(loaded["refresh_token"] == "refresh")
        #expect(FileManager.default.fileExists(atPath: store.primaryURL.path))
        #expect(FileManager.default.fileExists(atPath: store.backupURL.path))
        #expect(try permissions(at: store.primaryURL) == 0o600)
        #expect(try permissions(at: store.backupURL) == 0o600)
        #expect(logs.lines.contains("[chatgpt-auth] wrote chatgpt-auth.json reason=save"))
        #expect(logs.lines.contains("[chatgpt-auth] wrote chatgpt-auth.backup.json reason=save"))
    }

    @Test("token store restores primary from backup and logs restore")
    func tokenStoreRestoresPrimaryFromBackup() throws {
        let root = try makeTokenTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = TestLogSink()
        let store = makeTokenStore(root: root, logs: logs)
        try store.save(Self.sampleTokens, reason: "save")
        try FileManager.default.removeItem(at: store.primaryURL)
        logs.lines.removeAll()

        let loaded = try #require(store.load())

        #expect(loaded["access_token"] == "access")
        #expect(FileManager.default.fileExists(atPath: store.primaryURL.path))
        #expect(logs.lines.contains("[chatgpt-auth] restored tokens from backup reason=restore"))
    }

    @Test("token store sign-out removes primary and backup and leaves marker")
    func tokenStoreSignOutLeavesSignedOutMarker() throws {
        let root = try makeTokenTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = TestLogSink()
        let store = makeTokenStore(root: root, logs: logs)
        try store.save(Self.sampleTokens, reason: "save")
        logs.lines.removeAll()

        store.signOut()

        #expect(!FileManager.default.fileExists(atPath: store.primaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))
        #expect(FileManager.default.fileExists(atPath: store.signedOutURL.path))
        #expect(store.load() == nil)
        let signedOutTokensOrNil = try tokens(at: store.signedOutURL)
        let signedOutTokens = try #require(signedOutTokensOrNil)
        #expect(signedOutTokens["access_token"] == "access")
        #expect(logs.lines.contains("[chatgpt-auth] renamed chatgpt-auth.json to chatgpt-auth.signed-out.json reason=sign-out"))
        #expect(logs.lines.contains("[chatgpt-auth] deleted chatgpt-auth.backup.json reason=sign-out"))
    }

    // MARK: - Helpers

    private static let sampleTokens = [
        "access_token": "access",
        "refresh_token": "refresh",
        "expires_at": "4102444800000",
        "account_id": "acct",
    ]

    /// Build a fake JWT with the given JSON payload (header and signature are dummy values).
    private func makeJWT(payload: String) -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8).base64URLEncoded()
        let body = Data(payload.utf8).base64URLEncoded()
        let signature = "fake_signature"
        return "\(header).\(body).\(signature)"
    }

    private func makeTokenTestDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatgpt-auth-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeTokenStore(root: URL, logs: TestLogSink) -> AuthTokenFileStore {
        AuthTokenFileStore(
            primaryURL: root.appendingPathComponent("chatgpt-auth.json"),
            logPrefix: "chatgpt-auth",
            logger: { logs.append($0) }
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }

    private func tokens(at url: URL) throws -> [String: String]? {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: String]
    }

    private final class TestLogSink {
        var lines: [String] = []

        func append(_ line: String) {
            lines.append(line)
        }
    }
}
