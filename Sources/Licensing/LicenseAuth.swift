import AppKit
import AuthenticationServices
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
    static let callbackScheme = "transeen"
    static let callbackURL = URL(string: "transeen://auth-callback")!
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
        var components = URLComponents(
            url: authBase.appending(path: "authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: LicensePurchaseLinks.callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
            URLQueryItem(name: "apikey", value: configuration.publishableKey)
        ]
        guard let authorizeURL = components?.url else {
            throw LicenseAuthError.notConfigured
        }

        let callbackURL = try await browser.open(authorizeURL, callbackScheme: LicensePurchaseLinks.callbackScheme)
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
        var request = URLRequest(url: authBase.appending(path: "logout"))
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

    private static func authCode(from callbackURL: URL) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            if error == "access_denied" {
                throw LicenseAuthError.cancelled
            }
            throw LicenseAuthError.rejected(error)
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
    func open(_ url: URL, callbackScheme: String) async throws -> URL
}

struct SystemLicenseOAuthBrowser: LicenseOAuthBrowsing {
    func open(_ url: URL, callbackScheme: String) async throws -> URL {
        let result = LicenseOAuthResult()
        return try await withCheckedThrowingContinuation { continuation in
            result.attach(continuation)
            let completion = Self.completion(for: result)
            Task { @MainActor in
                LicenseOAuthSessions.shared.start(url: url, callbackScheme: callbackScheme, completion: completion)
            }
        }
    }

    /// AuthenticationServices calls this on its own XPC queue, not the main thread.
    /// It is built in a nonisolated context so Swift does not infer main-actor
    /// isolation for it (an isolated closure traps when called off-main), and it
    /// only touches `LicenseOAuthResult`, which is thread-safe.
    nonisolated static func completion(for result: LicenseOAuthResult) -> @Sendable (URL?, (any Error)?) -> Void {
        { callbackURL, error in
            if let callbackURL {
                result.finish(.success(callbackURL))
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                result.finish(.failure(LicenseAuthError.cancelled))
            } else {
                result.finish(.failure(error ?? LicenseAuthError.invalidCallback))
            }
        }
    }
}

/// Resumes the sign-in continuation exactly once, from whichever thread finishes first.
final class LicenseOAuthResult: @unchecked Sendable {
    private enum State {
        case waiting
        case attached(CheckedContinuation<URL, any Error>)
        case early(Result<URL, any Error>)
        case done
    }

    private let lock = NSLock()
    private var state = State.waiting

    func attach(_ continuation: CheckedContinuation<URL, any Error>) {
        lock.lock()
        switch state {
        case .waiting:
            state = .attached(continuation)
            lock.unlock()
        case .early(let result):
            state = .done
            lock.unlock()
            continuation.resume(with: result)
        case .attached, .done:
            lock.unlock()
        }
    }

    func finish(_ result: Result<URL, any Error>) {
        lock.lock()
        switch state {
        case .waiting:
            state = .early(result)
            lock.unlock()
        case .attached(let continuation):
            state = .done
            lock.unlock()
            continuation.resume(with: result)
        case .early, .done:
            lock.unlock()
        }
    }
}

/// Keeps each session and its presentation provider alive until the session
/// reports back; `presentationContextProvider` is weak and an unretained
/// session can be torn down mid-flow.
@MainActor
final class LicenseOAuthSessions {
    static let shared = LicenseOAuthSessions()
    private var active: [UUID: (session: ASWebAuthenticationSession, anchor: any ASWebAuthenticationPresentationContextProviding)] = [:]

    func start(url: URL, callbackScheme: String, completion: @escaping @Sendable (URL?, (any Error)?) -> Void) {
        let id = UUID()
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme,
            completionHandler: Self.releasing(id, after: completion)
        )
        let anchor = LicenseOAuthPresentationAnchor(
            window: NSApp.keyWindow
                ?? NSApp.windows.first(where: \.isVisible)
                ?? NSApp.windows.first
                ?? ASPresentationAnchor()
        )
        session.presentationContextProvider = anchor
        session.prefersEphemeralWebBrowserSession = false
        active[id] = (session, anchor)
        if !session.start() {
            active[id] = nil
            completion(nil, LicenseAuthError.invalidCallback)
        }
    }

    /// Built outside the main actor for the same reason as
    /// `SystemLicenseOAuthBrowser.completion(for:)`: the system calls it off-main.
    nonisolated static func releasing(
        _ id: UUID,
        after completion: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { callbackURL, error in
            completion(callbackURL, error)
            Task { @MainActor in LicenseOAuthSessions.shared.release(id) }
        }
    }

    private func release(_ id: UUID) {
        active[id] = nil
    }
}

/// The window is chosen on the main thread before the session starts, so
/// answering the system's request reads no AppKit state and is safe on any thread.
private final class LicenseOAuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    private let window: ASPresentationAnchor

    init(window: ASPresentationAnchor) {
        self.window = window
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
