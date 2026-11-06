import AppKit
import CryptoKit
import Foundation
import Security

enum LicenseAuthProvider: String, Equatable, Sendable {
    case google
    case github
}

/// Where the membership is bought and where sign-in returns to the app.
enum LicensePurchaseLinks {
    /// itool.tech redirects to the visitor's language; `from` tells it which product sent them.
    static func membershipURL(language: AppLanguage = InterfaceLanguage.shared.language) -> URL {
        let locale = language == .zhHans || language == .zhHant ? "zh" : "en"
        return URL(string: "https://itool.tech/\(locale)/pro?from=transeen")!
    }
}

struct LicenseAuthSession: Codable, Equatable, Sendable {
    var userID: UUID
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
    var provider: String?

    var isExpired: Bool {
        expiresAt.timeIntervalSinceNow < 60
    }
}

enum LicenseAuthError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case cancelled
    case invalidCallback
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Sign-in is not configured in this build."
        case .cancelled:
            "Sign-in was cancelled."
        case .invalidCallback:
            "Sign-in did not return a usable session."
        case let .rejected(message):
            message
        }
    }
}

protocol LicenseAuthSessionStoring: Sendable {
    func load() throws -> LicenseAuthSession?
    func save(_ session: LicenseAuthSession) throws
    func clear() throws
}

protocol LicenseAuthFlowPerforming: Sendable {
    func signIn(provider: LicenseAuthProvider) async throws -> LicenseAuthSession
    func signIn(email: String, password: String) async throws -> LicenseAuthSession
    func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession
    func signOut(_ session: LicenseAuthSession) async
}

final class KeychainLicenseAuthStore: LicenseAuthSessionStoring, @unchecked Sendable {
    private let item = SilentKeychainItem(service: "com.transeen.app.auth.v1", account: "supabase-session")

    func load() throws -> LicenseAuthSession? {
        guard let data = try item.read() else { return nil }
        do {
            return try JSONDecoder().decode(LicenseAuthSession.self, from: data)
        } catch {
            throw EntitlementServiceError.storage("The saved sign-in session is damaged.")
        }
    }

    func save(_ session: LicenseAuthSession) throws {
        try item.write(try JSONEncoder().encode(session))
    }

    func clear() throws {
        try item.delete()
    }
}

struct SupabaseLicenseAuthClient: LicenseAuthFlowPerforming {
    private let configuration: LicenseRemoteConfiguration
    private let transport: any LicenseHTTPTransport
    private let browser: any LicenseOAuthBrowsing

    init(
        configuration: LicenseRemoteConfiguration,
        transport: any LicenseHTTPTransport = URLSessionLicenseTransport(),
        browser: any LicenseOAuthBrowsing = SystemLicenseOAuthBrowser()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.browser = browser
    }

    func signIn(provider: LicenseAuthProvider) async throws -> LicenseAuthSession {
        guard let authBase = configuration.authBaseURL,
              !configuration.publishableKey.isEmpty else {
            throw LicenseAuthError.notConfigured
        }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.makeCodeChallenge(verifier)
        let key = configuration.publishableKey
        let callbackURL = try await browser.authorize { redirect in
            Self.authorizeURL(authBase: authBase, provider: provider, redirect: redirect, challenge: challenge, publishableKey: key)
        }
        let authCode = try Self.authCode(from: callbackURL)
        return try await exchange(authCode: authCode, codeVerifier: verifier, authBase: authBase)
    }

    func signIn(email: String, password: String) async throws -> LicenseAuthSession {
        guard let authBase = configuration.authBaseURL,
              !configuration.publishableKey.isEmpty else {
            throw LicenseAuthError.notConfigured
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            throw LicenseAuthError.rejected("Enter an email and password.")
        }

        var tokenURL = authBase.appending(path: "token")
        var tokenComponents = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)
        tokenComponents?.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        tokenURL = tokenComponents?.url ?? tokenURL
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": trimmedEmail,
            "password": password
        ])

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (payload?["error_description"] as? String)
                ?? (payload?["msg"] as? String)
                ?? (payload?["error"] as? String)
                ?? "Email sign-in failed."
            throw LicenseAuthError.rejected(message)
        }
        return try Self.decodeSession(from: data, fallbackProvider: "email")
    }

    func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession {
        guard let authBase = configuration.authBaseURL,
              !configuration.publishableKey.isEmpty else {
            throw LicenseAuthError.notConfigured
        }

        var tokenURL = authBase.appending(path: "token")
        var tokenComponents = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)
        tokenComponents?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        tokenURL = tokenComponents?.url ?? tokenURL
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": session.refreshToken
        ])

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            // 400/401/403 mean the refresh token is no longer valid. Anything else is an outage
            // and must not sign the user out.
            if [400, 401, 403].contains(response.statusCode) {
                throw LicenseAuthError.rejected("Could not refresh the sign-in session.")
            }
            throw EntitlementServiceError.temporarilyUnavailable
        }
        return try Self.decodeSession(from: data, fallbackProvider: session.provider)
    }

    func signOut(_ session: LicenseAuthSession) async {
        guard let authBase = configuration.authBaseURL,
              !configuration.publishableKey.isEmpty else {
            return
        }
        // Only this sign-in: without the scope Supabase ends every session of the account, on
        // itool.tech and in the other iTool apps too.
        var components = URLComponents(url: authBase.appending(path: "logout"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "scope", value: "local")]
        var request = URLRequest(url: components?.url ?? authBase.appending(path: "logout"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await transport.data(for: request)
    }

    private func exchange(
        authCode: String,
        codeVerifier: String,
        authBase: URL
    ) async throws -> LicenseAuthSession {
        var tokenURL = authBase.appending(path: "token")
        var tokenComponents = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)
        tokenComponents?.queryItems = [URLQueryItem(name: "grant_type", value: "pkce")]
        tokenURL = tokenComponents?.url ?? tokenURL
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "auth_code": authCode,
            "code_verifier": codeVerifier
        ])

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LicenseAuthError.rejected("Sign-in did not complete.")
        }
        return try Self.decodeSession(from: data, fallbackProvider: nil)
    }

    private static func decodeSession(from data: Data, fallbackProvider: String?) throws -> LicenseAuthSession {
        let payload = try JSONSerialization.jsonObject(with: data)
        guard let json = payload as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              !accessToken.isEmpty,
              !refreshToken.isEmpty else {
            throw LicenseAuthError.invalidCallback
        }

        let expiresIn = (json["expires_in"] as? Int) ?? 3600
        let user = json["user"] as? [String: Any]
        let userIDString = user?["id"] as? String
        guard let userIDString, let userID = UUID(uuidString: userIDString) else {
            throw LicenseAuthError.invalidCallback
        }
        let identities = user?["identities"] as? [[String: Any]]
        let provider = (identities?.first?["provider"] as? String) ?? fallbackProvider
        return LicenseAuthSession(
            userID: userID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            email: user?["email"] as? String,
            provider: provider
        )
    }

    static func authorizeURL(authBase: URL, provider: LicenseAuthProvider, redirect: URL, challenge: String, publishableKey: String) -> URL {
        var components = URLComponents(url: authBase.appending(path: "authorize"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: redirect.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
            URLQueryItem(name: "apikey", value: publishableKey)
        ]
        // Without user:email a GitHub account with a private address has none.
        if provider == .github { items.append(URLQueryItem(name: "scopes", value: "read:user user:email")) }
        components.queryItems = items
        return components.url!
    }

    static func authCode(from callbackURL: URL) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let item = { (name: String) in components?.queryItems?.first(where: { $0.name == name })?.value }
        if let error = item("error") ?? item("error_code") {
            if error == "access_denied" || error == "no_code" {
                throw LicenseAuthError.cancelled
            }
            throw LicenseAuthError.rejected(item("error_description") ?? error)
        }
        if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return code
        }
        throw LicenseAuthError.invalidCallback
    }

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func makeCodeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

protocol LicenseOAuthBrowsing: Sendable {
    /// Opens the authorize URL built for `redirect` and returns the URL the browser came back to.
    func authorize(_ build: @escaping @Sendable (URL) -> URL) async throws -> URL
}

/// The person's own browser, back to a loopback listener (LoopbackOAuth.swift).
struct SystemLicenseOAuthBrowser: LicenseOAuthBrowsing {
    func authorize(_ build: @escaping @Sendable (URL) -> URL) async throws -> URL {
        do {
            let url = try await LoopbackOAuth.run(productName: "Transeen", authorize: build)
            await MainActor.run { NSApp.activate() }
            return url
        } catch LoopbackOAuthError.cancelled {
            throw LicenseAuthError.cancelled
        } catch LoopbackOAuthError.timedOut {
            throw LicenseAuthError.rejected("Sign-in timed out. Try again.")
        } catch LoopbackOAuthError.unavailable {
            throw LicenseAuthError.rejected("Could not start sign-in. Try again.")
        }
    }
}
