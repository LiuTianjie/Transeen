import AppKit
import Combine
import Foundation
import LocalAuthentication
import Network
import Security

/// iTool membership tiers as the server reports them.
enum MembershipTier: String, Codable, Equatable, Sendable {
    case free, monthly, yearly
}

/// The server's answer for product `transeen` and the signed-in user.
struct Entitlement: Codable, Equatable, Sendable {
    var active: Bool
    var tier: MembershipTier
    var requiredTier: MembershipTier = .yearly
    /// The end of access; nil while active means no end (a manual grant).
    var validUntil: Date?
    var memberUntil: Date?
    var yearlyUntil: Date?
    var serverTime: Date
}

/// The last successful check, kept in the Keychain so the app works offline for a while.
struct EntitlementCache: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var userID: UUID
    var entitlement: Entitlement
    /// The local clock when the server answered. Offline use is measured on the local
    /// timeline from here, so a Mac whose clock is off by a constant amount still works.
    var checkedAt: Date
    /// The latest local time seen while this cache was in use. Going back past it is a rollback.
    var lastSeenAt: Date
}

enum EntitlementVerdict: Equatable, Sendable {
    case active
    /// The server said no: no membership, or a tier below the one Transeen needs.
    case inactive
    /// Offline past the cached `valid_until`; the server may have renewed it.
    case expired
    /// Offline for longer than the allowed window.
    case stale
    /// The local clock is earlier than a time already seen.
    case clockRolledBack
}

/// The offline rule: after a successful check with `active: true`, use is allowed offline for at
/// most seven days and never past `valid_until`. A clock set back past the check, or past any time
/// seen since, needs a fresh check.
enum EntitlementPolicy {
    static let offlineWindow: TimeInterval = 7 * 24 * 60 * 60
    static let clockTolerance: TimeInterval = 5 * 60

    static func verdict(for cache: EntitlementCache, now: Date) -> EntitlementVerdict {
        guard cache.entitlement.active else { return .inactive }
        let earliestAllowed = max(cache.checkedAt, cache.lastSeenAt).addingTimeInterval(-clockTolerance)
        if now < earliestAllowed { return .clockRolledBack }
        let elapsed = max(0, now.timeIntervalSince(cache.checkedAt))
        if let validUntil = cache.entitlement.validUntil,
           elapsed >= validUntil.timeIntervalSince(cache.entitlement.serverTime) {
            return .expired
        }
        if elapsed >= offlineWindow { return .stale }
        return .active
    }

    /// The local time until which the cache allows use without another check.
    static func offlineUntil(for cache: EntitlementCache) -> Date? {
        guard cache.entitlement.active else { return nil }
        var until = cache.checkedAt.addingTimeInterval(offlineWindow)
        if let validUntil = cache.entitlement.validUntil {
            until = min(until, cache.checkedAt.addingTimeInterval(validUntil.timeIntervalSince(cache.entitlement.serverTime)))
        }
        return until
    }
}

enum LicenseState: Equatable, Sendable {
    case checking
    case signedOut
    /// Signed in with an active yearly membership (or a grant).
    case entitled(Entitlement)
    /// Signed in, and the server said this account has no access to Transeen.
    case notEntitled(Entitlement)
    /// Signed in, but the cached answer can no longer be trusted and the server could not be reached.
    case needsCheck(Entitlement?)

    var isEntitled: Bool {
        if case .entitled = self { return true }
        return false
    }

    var isSignedIn: Bool {
        switch self {
        case .signedOut: false
        default: true
        }
    }

    /// The last membership the server reported, if any.
    var entitlement: Entitlement? {
        switch self {
        case let .entitled(value), let .notEntitled(value): value
        case let .needsCheck(value): value
        case .checking, .signedOut: nil
        }
    }
}

protocol EntitlementCacheStoring: Sendable {
    func load() throws -> EntitlementCache?
    func save(_ cache: EntitlementCache) throws
    func clear() throws
}

protocol EntitlementRemoteServicing: Sendable {
    func entitlement(accessToken: String) async throws -> Entitlement
}

protocol LicenseClock: Sendable {
    var now: Date { get }
}

struct SystemLicenseClock: LicenseClock {
    var now: Date { Date() }
}

enum EntitlementServiceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    /// The access token was refused; refresh it or sign in again.
    case loginRequired
    /// Network failure or a server error. Keep the cached state.
    case temporarilyUnavailable
    case invalidResponse
    case requestInProgress
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Membership checks are not configured in this build."
        case .loginRequired: "Sign in to your iTool account again."
        case .temporarilyUnavailable: "The membership service could not be reached."
        case .invalidResponse: "The membership service returned an invalid response."
        case .requestInProgress: "A request is already in progress."
        case let .storage(message): message
        }
    }
}

/// Owns the app-wide gate: signed in to an iTool account whose membership includes Transeen.
@MainActor
final class LicenseManager: ObservableObject {
    nonisolated static let productKey = "transeen"
    /// How old a successful check may get before the next gate use or activation checks again.
    static let revalidationInterval: TimeInterval = 6 * 60 * 60
    /// The shortest gap between automatic checks, so a stream of gate calls stays offline.
    static let retryInterval: TimeInterval = 30
    /// `lastSeenAt` is written back to the Keychain at most this often.
    static let lastSeenPersistInterval: TimeInterval = 60 * 60

    @Published private(set) var state: LicenseState = .checking
    @Published private(set) var authSession: LicenseAuthSession?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isChecking = false
    /// The latest check could not reach the server; the state comes from the cache.
    @Published private(set) var lastCheckFailed = false

    private let store: any EntitlementCacheStoring
    private let remote: any EntitlementRemoteServicing
    private let clock: any LicenseClock
    private let authStore: any LicenseAuthSessionStoring
    private let authFlow: any LicenseAuthFlowPerforming

    private var cache: EntitlementCache?
    private var persistedLastSeenAt: Date?
    private var lastAttemptAt: Date?
    private var didBootstrap = false
    private var checkTask: Task<Void, Never>?
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var networkWasDown = false
    private var wakeObserver: NSObjectProtocol?

    init(
        store: any EntitlementCacheStoring,
        remote: any EntitlementRemoteServicing,
        clock: any LicenseClock = SystemLicenseClock(),
        authStore: any LicenseAuthSessionStoring = MemoryLicenseAuthStore(),
        authFlow: any LicenseAuthFlowPerforming = UnavailableLicenseAuthFlow()
    ) {
        self.store = store
        self.remote = remote
        self.clock = clock
        self.authStore = authStore
        self.authFlow = authFlow
    }

    static func live(bundle: Bundle = .main) -> LicenseManager {
        let configuration = LicenseRemoteConfiguration.from(bundle: bundle)
        return LicenseManager(
            store: KeychainEntitlementStore(),
            remote: MembershipEntitlementClient(configuration: configuration),
            authStore: KeychainLicenseAuthStore(),
            authFlow: SupabaseLicenseAuthClient(configuration: configuration)
        )
    }

    /// Until when the cached answer allows use without reaching the server.
    var offlineUntil: Date? {
        cache.flatMap(EntitlementPolicy.offlineUntil(for:))
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        authSession = try? authStore.load()
        do {
            cache = try store.load()
        } catch {
            // A damaged cache only costs one online check.
            try? store.clear()
            cache = nil
        }
        persistedLastSeenAt = cache?.lastSeenAt
        if let cached = cache, cached.userID != authSession?.userID {
            discardCache()
        }
        didBootstrap = true
        refreshState()
        revalidate(force: true, immediately: true)
    }

    /// Re-reads the gate from the cache and starts a server check when one is due. Cheap enough
    /// to call on every gate use. `force` checks even when the cached answer is fresh; checks are
    /// still at least `retryInterval` apart unless `immediately` is set.
    func revalidate(force: Bool = false, immediately: Bool = false) {
        refreshState()
        guard didBootstrap, authSession != nil, checkTask == nil else { return }
        let now = clock.now
        if !immediately, let last = lastAttemptAt {
            let since = now.timeIntervalSince(last)
            if since >= 0 && since < Self.retryInterval { return }
        }
        if !force {
            if state.isEntitled, let cache {
                let age = now.timeIntervalSince(cache.checkedAt)
                if age >= 0 && age < Self.revalidationInterval { return }
            }
        }
        lastAttemptAt = now
        isChecking = true
        if case .needsCheck(nil) = state { setState(.checking) }
        checkTask = Task { @MainActor [weak self] in
            await self?.performCheck()
        }
    }

    /// The "Refresh membership" button: checks now and waits for the answer.
    func refreshMembership() async {
        await bootstrap()
        revalidate(force: true, immediately: true)
        await waitForCheck()
    }

    func waitForCheck() async {
        await checkTask?.value
    }

    func signIn(provider: LicenseAuthProvider) async throws {
        try await signIn { try await self.authFlow.signIn(provider: provider) }
    }

    func signIn(email: String, password: String) async throws {
        try await signIn { try await self.authFlow.signIn(email: email, password: password) }
    }

    func signOut() async {
        let session = authSession
        clearLocalAccount()
        if let session { await authFlow.signOut(session) }
    }

    /// Hourly re-evaluation, plus a check after wake and when the network returns.
    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.revalidate() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.revalidate(force: true) }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(reachable: reachable) }
        }
        monitor.start(queue: DispatchQueue(label: "com.transeen.app.network-monitor"))
        pathMonitor = monitor
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        timer?.invalidate()
        timer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    // MARK: - Checking

    private enum CheckFailure: Error {
        case signedOut
    }

    private func performCheck() async {
        defer {
            checkTask = nil
            isChecking = false
            refreshState()
        }
        guard let userID = authSession?.userID else { return }
        do {
            let entitlement = try await fetchRefreshingOnce()
            guard !Task.isCancelled, authSession?.userID == userID else { return }
            store(entitlement, for: userID)
            lastCheckFailed = false
        } catch CheckFailure.signedOut {
            guard authSession?.userID == userID else { return }
            clearLocalAccount()
        } catch {
            guard authSession?.userID == userID else { return }
            // Network failures and server errors keep the cached state.
            lastCheckFailed = true
        }
    }

    /// One request; on `login_required` refresh the token and try exactly once more.
    private func fetchRefreshingOnce() async throws -> Entitlement {
        guard var session = authSession else { throw CheckFailure.signedOut }
        if session.isExpired { session = try await refresh(session) }
        do {
            return try await remote.entitlement(accessToken: session.accessToken)
        } catch EntitlementServiceError.loginRequired {
            session = try await refresh(session)
            do {
                return try await remote.entitlement(accessToken: session.accessToken)
            } catch EntitlementServiceError.loginRequired {
                throw CheckFailure.signedOut
            }
        }
    }

    private func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession {
        let refreshed: LicenseAuthSession
        do {
            refreshed = try await authFlow.refresh(session)
        } catch LicenseAuthError.rejected {
            // The refresh token itself was refused: the session is over.
            throw CheckFailure.signedOut
        } catch {
            throw EntitlementServiceError.temporarilyUnavailable
        }
        guard authSession?.userID == session.userID else { throw CheckFailure.signedOut }
        try? authStore.save(refreshed)
        authSession = refreshed
        return refreshed
    }

    private func store(_ entitlement: Entitlement, for userID: UUID) {
        let now = clock.now
        let fresh = EntitlementCache(userID: userID, entitlement: entitlement, checkedAt: now, lastSeenAt: now)
        cache = fresh
        // A failed write still serves this run; the next launch checks again.
        if (try? store.save(fresh)) != nil { persistedLastSeenAt = now }
    }

    // MARK: - State

    private func refreshState() {
        guard didBootstrap else { return }
        guard let session = authSession else {
            setState(.signedOut)
            return
        }
        guard var current = cache, current.userID == session.userID else {
            setState(isChecking ? .checking : .needsCheck(nil))
            return
        }
        let now = clock.now
        switch EntitlementPolicy.verdict(for: current, now: now) {
        case .active:
            if now > current.lastSeenAt {
                current.lastSeenAt = now
                cache = current
                let persisted = persistedLastSeenAt ?? .distantPast
                if now.timeIntervalSince(persisted) >= Self.lastSeenPersistInterval,
                   (try? store.save(current)) != nil {
                    persistedLastSeenAt = now
                }
            }
            setState(.entitled(current.entitlement))
        case .inactive:
            setState(.notEntitled(current.entitlement))
        case .expired, .stale, .clockRolledBack:
            setState(.needsCheck(current.entitlement))
        }
    }

    private func setState(_ value: LicenseState) {
        if state != value { state = value }
    }

    private func signIn(_ perform: @escaping @MainActor () async throws -> LicenseAuthSession) async throws {
        await bootstrap()
        guard !isSigningIn else { throw EntitlementServiceError.requestInProgress }
        isSigningIn = true
        defer { isSigningIn = false }
        let session = try await perform()
        try authStore.save(session)
        if cache?.userID != session.userID { discardCache() }
        checkTask?.cancel()
        checkTask = nil
        authSession = session
        lastCheckFailed = false
        refreshState()
        revalidate(force: true, immediately: true)
    }

    private func clearLocalAccount() {
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
        try? authStore.clear()
        authSession = nil
        discardCache()
        lastCheckFailed = false
        refreshState()
    }

    private func discardCache() {
        try? store.clear()
        cache = nil
        persistedLastSeenAt = nil
    }

    private func networkChanged(reachable: Bool) {
        defer { networkWasDown = !reachable }
        if reachable && networkWasDown { revalidate(force: true) }
    }
}

// MARK: - Keychain

/// A generic-password item read and written without ever showing a Keychain dialog.
///
/// Developer ID releases are signed directly and do not embed the provisioning profile the Data
/// Protection Keychain needs, so this uses the login Keychain. An ACL mismatch must never turn a
/// background check into a password prompt: `LAContext.interactionNotAllowed` covers modern
/// authentication, and the file-based Keychain's legacy UI switch is turned off around each call.
struct SilentKeychainItem: Sendable {
    let service: String
    let account: String
    private static let interactionLock = NSLock()

    var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private var nonInteractiveQuery: [String: Any] {
        var query = identity
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    func read() throws -> Data? {
        try withoutInteraction {
            var query = nonInteractiveQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status) }
            return data
        }
    }

    func write(_ data: Data) throws {
        try withoutInteraction {
            let updateStatus = SecItemUpdate(nonInteractiveQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if updateStatus == errSecSuccess { return }
            guard updateStatus == errSecItemNotFound else { throw Self.error(updateStatus) }
            var attributes = identity
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.error(addStatus) }
        }
    }

    func delete() throws {
        try withoutInteraction {
            let status = SecItemDelete(nonInteractiveQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
        }
    }

    private func withoutInteraction<Value>(_ operation: () throws -> Value) throws -> Value {
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }
        var wasAllowed = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&wasAllowed)
        guard readStatus == errSecSuccess else { throw Self.error(readStatus) }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else { throw Self.error(disableStatus) }
        defer { _ = SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return try operation()
    }

    private static func error(_ status: OSStatus) -> EntitlementServiceError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        return .storage("Could not access the Keychain: \(message)")
    }
}

final class KeychainEntitlementStore: EntitlementCacheStoring, @unchecked Sendable {
    private let item = SilentKeychainItem(service: "com.transeen.app.entitlement.v1", account: "itool-membership")

    func load() throws -> EntitlementCache? {
        guard let data = try item.read() else { return nil }
        return try JSONDecoder().decode(EntitlementCache.self, from: data)
    }

    func save(_ cache: EntitlementCache) throws {
        try item.write(try JSONEncoder().encode(cache))
    }

    func clear() throws {
        try item.delete()
    }
}

final class MemoryEntitlementStore: EntitlementCacheStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: EntitlementCache?

    init(_ value: EntitlementCache? = nil) { self.value = value }

    func load() throws -> EntitlementCache? { lock.withLock { value } }
    func save(_ cache: EntitlementCache) throws { lock.withLock { value = cache } }
    func clear() throws { lock.withLock { value = nil } }
}

// MARK: - Server

struct LicenseRemoteConfiguration: Sendable {
    let supabaseURL: URL?
    let publishableKey: String
    let entitlementURL: URL?
    let appVersion: String

    /// Supabase Auth (`…/auth/v1`).
    var authBaseURL: URL? {
        supabaseURL.map { $0.appending(path: "auth/v1") }
    }

    var rpcURL: URL? {
        supabaseURL.map { $0.appending(path: "rest/v1/rpc/itool_entitlement") }
    }

    static func from(bundle: Bundle) -> LicenseRemoteConfiguration {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func https(_ string: String) -> URL? {
            guard let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
            return url
        }
        return LicenseRemoteConfiguration(
            supabaseURL: https(value("TranseenSupabaseURL")),
            publishableKey: value("TranseenSupabasePublishableKey"),
            entitlementURL: https(value("TranseenEntitlementURL")),
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        )
    }
}

protocol LicenseHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionLicenseTransport: LicenseHTTPTransport {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw EntitlementServiceError.invalidResponse
        }
        return (data, response)
    }
}

/// Asks `itool.tech/api/membership/entitlement`, which works where supabase.co is blocked, and falls
/// back to the `itool_entitlement` RPC on Supabase when that fails for any reason but the token.
struct MembershipEntitlementClient: EntitlementRemoteServicing {
    private let configuration: LicenseRemoteConfiguration
    private let transport: any LicenseHTTPTransport

    init(configuration: LicenseRemoteConfiguration, transport: any LicenseHTTPTransport = URLSessionLicenseTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    func entitlement(accessToken: String) async throws -> Entitlement {
        guard !accessToken.isEmpty else { throw EntitlementServiceError.loginRequired }
        do {
            return try await fromWebsite(accessToken: accessToken)
        } catch EntitlementServiceError.loginRequired {
            throw EntitlementServiceError.loginRequired
        } catch {
            return try await fromSupabase(accessToken: accessToken)
        }
    }

    private func fromWebsite(accessToken: String) async throws -> Entitlement {
        guard let base = configuration.entitlementURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw EntitlementServiceError.notConfigured
        }
        components.queryItems = [URLQueryItem(name: "product", value: LicenseManager.productKey)]
        guard let url = components.url else { throw EntitlementServiceError.notConfigured }
        var request = baseRequest(url: url, accessToken: accessToken)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func fromSupabase(accessToken: String) async throws -> Entitlement {
        guard let url = configuration.rpcURL, !configuration.publishableKey.isEmpty else {
            throw EntitlementServiceError.notConfigured
        }
        var request = baseRequest(url: url, accessToken: accessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["p_product": LicenseManager.productKey])
        return try await send(request)
    }

    private func baseRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Transeen/\(configuration.appVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Entitlement {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw EntitlementServiceError.temporarilyUnavailable
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = payload?["code"] as? String
        if response.statusCode == 401 || response.statusCode == 403 || code == "login_required" {
            throw EntitlementServiceError.loginRequired
        }
        guard (200..<300).contains(response.statusCode), let payload else {
            throw EntitlementServiceError.temporarilyUnavailable
        }
        return try Self.parse(payload)
    }

    static func parse(_ payload: [String: Any]) throws -> Entitlement {
        guard payload["ok"] as? Bool == true,
              let active = payload["active"] as? Bool,
              let serverTime = date(payload["server_time"]) else {
            throw EntitlementServiceError.invalidResponse
        }
        if let product = payload["product"] as? String, product != LicenseManager.productKey {
            throw EntitlementServiceError.invalidResponse
        }
        return Entitlement(
            active: active,
            tier: MembershipTier(rawValue: payload["tier"] as? String ?? "") ?? .free,
            requiredTier: MembershipTier(rawValue: payload["required_tier"] as? String ?? "") ?? .yearly,
            validUntil: date(payload["valid_until"]),
            memberUntil: date(payload["member_until"]),
            yearlyUntil: date(payload["yearly_until"]),
            serverTime: serverTime
        )
    }

    /// Postgres writes `2026-11-05T10:20:24.968123+00:00`; Foundation's parser wants at most
    /// millisecond precision, so the fraction is cut to three digits first.
    static func date(_ value: Any?) -> Date? {
        guard var text = value as? String, !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: " ", with: "T")
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = text[range].dropFirst()
            text.replaceSubrange(range, with: "." + String((digits + "000").prefix(3)))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - Test and unconfigured stand-ins

final class MemoryLicenseAuthStore: LicenseAuthSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: LicenseAuthSession?

    init(session: LicenseAuthSession? = nil) {
        self.session = session
    }

    func load() throws -> LicenseAuthSession? { lock.withLock { session } }
    func save(_ session: LicenseAuthSession) throws { lock.withLock { self.session = session } }
    func clear() throws { lock.withLock { session = nil } }
}

struct UnavailableLicenseAuthFlow: LicenseAuthFlowPerforming {
    func signIn(provider: LicenseAuthProvider) async throws -> LicenseAuthSession {
        throw LicenseAuthError.notConfigured
    }

    func signIn(email: String, password: String) async throws -> LicenseAuthSession {
        throw LicenseAuthError.notConfigured
    }

    func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession {
        throw LicenseAuthError.notConfigured
    }

    func signOut(_ session: LicenseAuthSession) async {}
}
