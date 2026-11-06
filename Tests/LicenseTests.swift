import Foundation

final class TestClock: LicenseClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// Answers with a scripted result per call; the last script entry repeats.
actor TestRemote: EntitlementRemoteServicing {
    enum Reply { case entitlement(Entitlement), failure(EntitlementServiceError) }
    private var script: [Reply]
    private(set) var tokens: [String] = []
    init(_ script: [Reply]) { self.script = script }
    func reply(_ script: [Reply]) { self.script = script }
    func entitlement(accessToken: String) async throws -> Entitlement {
        tokens.append(accessToken)
        let next = script.count > 1 ? script.removeFirst() : script[0]
        switch next {
        case let .entitlement(value): return value
        case let .failure(error): throw error
        }
    }
}

final class TestAuthFlow: LicenseAuthFlowPerforming, @unchecked Sendable {
    enum Outcome { case success, rejected, outage }
    private let lock = NSLock()
    private var outcome: Outcome = .success
    private var count = 0
    var refreshes: Int { lock.withLock { count } }
    func refreshOutcome(_ value: Outcome) { lock.withLock { outcome = value } }
    func signIn(provider: LicenseAuthProvider) async throws -> LicenseAuthSession { throw LicenseAuthError.notConfigured }
    func signIn(email: String, password: String) async throws -> LicenseAuthSession { throw LicenseAuthError.notConfigured }
    func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession {
        let outcome = lock.withLock { count += 1; return self.outcome }
        switch outcome {
        case .success:
            var next = session
            next.accessToken = "refreshed-\(refreshes)"
            next.expiresAt = Date().addingTimeInterval(3600)
            return next
        case .rejected: throw LicenseAuthError.rejected("refresh token revoked")
        case .outage: throw EntitlementServiceError.temporarilyUnavailable
        }
    }
    func signOut(_ session: LicenseAuthSession) async {}
}

struct TestTransport: LicenseHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (Int, String)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = try handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

let day: TimeInterval = 24 * 60 * 60
let start = Date(timeIntervalSince1970: 1_800_000_000)

func yearly(until: Date? = start.addingTimeInterval(300 * day), serverTime: Date = start) -> Entitlement {
    Entitlement(active: true, tier: .yearly, validUntil: until, memberUntil: until, yearlyUntil: until, serverTime: serverTime)
}
let monthly = Entitlement(active: false, tier: .monthly, validUntil: nil, memberUntil: start.addingTimeInterval(20 * day), yearlyUntil: nil, serverTime: start)
let free = Entitlement(active: false, tier: .free, validUntil: nil, memberUntil: nil, yearlyUntil: nil, serverTime: start)

func session(_ user: UUID = UUID(), token: String = "token") -> LicenseAuthSession {
    LicenseAuthSession(userID: user, accessToken: token, refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600))
}

func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError("FAILED: \(message)") }
}

@MainActor
func makeManager(
    remote: TestRemote,
    clock: TestClock,
    store: MemoryEntitlementStore = MemoryEntitlementStore(),
    auth: MemoryLicenseAuthStore,
    flow: TestAuthFlow = TestAuthFlow()
) async -> LicenseManager {
    let manager = LicenseManager(store: store, remote: remote, clock: clock, authStore: auth, authFlow: flow)
    await manager.bootstrap()
    await manager.waitForCheck()
    return manager
}

@main struct LicenseTests {
    @MainActor static func main() async throws {
        try await gateStates()
        try await offlineWindow()
        try await clockRollback()
        try await explicitRevoke()
        try await loginRequiredRefresh()
        try await accountChanges()
        try await wireClient()
        try await loopbackOAuth()
        try await signOutIsLocal()
        check(ReleaseVersion("v0.10.0")! > ReleaseVersion("0.9.9")!, "version order")
        check(ReleaseVersion("0.7") == ReleaseVersion("0.7.0"), "version padding")
        check(ReleaseVersion("0.7.0-beta") == nil, "pre-release versions are ignored")
        print("Membership gate, offline window, clock rollback, revocation, token refresh, account changes, wire client and update version checks passed")
    }

    @MainActor static func gateStates() async throws {
        let clock = TestClock(start)
        let remote = TestRemote([.entitlement(yearly())])
        let signedOut = await makeManager(remote: remote, clock: clock, auth: MemoryLicenseAuthStore())
        check(signedOut.state == .signedOut && !signedOut.state.isEntitled, "no session means signed out")
        check(await remote.tokens.isEmpty, "a signed-out app never calls the server")

        let store = MemoryEntitlementStore()
        let user = UUID()
        let member = await makeManager(remote: remote, clock: clock, store: store, auth: MemoryLicenseAuthStore(session: session(user)))
        check(member.state.isEntitled, "a yearly member is entitled")
        check(try store.load()?.userID == user, "the answer is cached for this user")

        await remote.reply([.entitlement(monthly)])
        let monthlyMember = await makeManager(remote: remote, clock: clock, auth: MemoryLicenseAuthStore(session: session()))
        guard case let .notEntitled(value) = monthlyMember.state else { fatalError("FAILED: monthly must not unlock Transeen") }
        check(value.tier == .monthly, "the monthly tier is reported so the UI can offer an upgrade")

        await remote.reply([.entitlement(free)])
        let nonMember = await makeManager(remote: remote, clock: clock, auth: MemoryLicenseAuthStore(session: session()))
        check(nonMember.state == .notEntitled(free), "a free account is signed in but not entitled")

        await remote.reply([.failure(.temporarilyUnavailable)])
        let neverChecked = await makeManager(remote: remote, clock: clock, auth: MemoryLicenseAuthStore(session: session()))
        check(neverChecked.state == .needsCheck(nil) && neverChecked.lastCheckFailed, "no cache and no network: not entitled")
    }

    @MainActor static func offlineWindow() async throws {
        let clock = TestClock(start)
        let store = MemoryEntitlementStore()
        let auth = MemoryLicenseAuthStore(session: session())
        let remote = TestRemote([.entitlement(yearly())])
        _ = await makeManager(remote: remote, clock: clock, store: store, auth: auth)

        await remote.reply([.failure(.temporarilyUnavailable)])
        clock.advance(3 * day)
        let relaunched = await makeManager(remote: remote, clock: clock, store: store, auth: auth)
        check(relaunched.state.isEntitled && relaunched.lastCheckFailed, "three days offline keeps working")
        check(relaunched.offlineUntil == start.addingTimeInterval(7 * day), "offline use ends 7 days after the check")

        clock.set(start.addingTimeInterval(7 * day - 60))
        relaunched.revalidate()
        await relaunched.waitForCheck()
        check(relaunched.state.isEntitled, "just inside the window")
        clock.set(start.addingTimeInterval(7 * day + 1))
        relaunched.revalidate()
        await relaunched.waitForCheck()
        check(relaunched.state == .needsCheck(yearly()), "past 7 days offline needs a check")

        await remote.reply([.entitlement(yearly(serverTime: start.addingTimeInterval(7 * day)))])
        await relaunched.refreshMembership()
        check(relaunched.state.isEntitled && !relaunched.lastCheckFailed, "back online the gate opens again")

        // valid_until earlier than the offline window wins, measured on the server's timeline:
        // the local clock here runs 3 hours behind the server.
        let skewedClock = TestClock(start.addingTimeInterval(-3 * 3600))
        let shortStore = MemoryEntitlementStore()
        let shortAuth = MemoryLicenseAuthStore(session: session())
        let short = TestRemote([.entitlement(yearly(until: start.addingTimeInterval(2 * day)))])
        _ = await makeManager(remote: short, clock: skewedClock, store: shortStore, auth: shortAuth)
        await short.reply([.failure(.temporarilyUnavailable)])
        skewedClock.advance(2 * day - 60)
        let beforeExpiry = await makeManager(remote: short, clock: skewedClock, store: shortStore, auth: shortAuth)
        check(beforeExpiry.state.isEntitled, "valid until the membership ends")
        skewedClock.advance(120)
        beforeExpiry.revalidate()
        await beforeExpiry.waitForCheck()
        check(!beforeExpiry.state.isEntitled, "never past valid_until while offline")
        guard case .needsCheck = beforeExpiry.state else { fatalError("FAILED: an expired cache asks for a check") }

        // A grant without an end is still bounded by the offline window.
        let open = EntitlementCache(userID: UUID(), entitlement: yearly(until: nil), checkedAt: start, lastSeenAt: start)
        check(EntitlementPolicy.verdict(for: open, now: start.addingTimeInterval(6 * day)) == .active, "open grant inside the window")
        check(EntitlementPolicy.verdict(for: open, now: start.addingTimeInterval(8 * day)) == .stale, "open grant outside the window")
    }

    @MainActor static func clockRollback() async throws {
        let cache = EntitlementCache(userID: UUID(), entitlement: yearly(), checkedAt: start, lastSeenAt: start.addingTimeInterval(4 * day))
        check(EntitlementPolicy.verdict(for: cache, now: start.addingTimeInterval(-day)) == .clockRolledBack, "clock before the check")
        check(EntitlementPolicy.verdict(for: cache, now: start.addingTimeInterval(2 * day)) == .clockRolledBack, "clock before a time already seen")
        check(EntitlementPolicy.verdict(for: cache, now: start.addingTimeInterval(4 * day - 60)) == .active, "a small clock correction is tolerated")

        let clock = TestClock(start)
        let store = MemoryEntitlementStore()
        let auth = MemoryLicenseAuthStore(session: session())
        let remote = TestRemote([.entitlement(yearly())])
        let manager = await makeManager(remote: remote, clock: clock, store: store, auth: auth)
        await remote.reply([.failure(.temporarilyUnavailable)])
        clock.advance(5 * day)
        manager.revalidate()
        await manager.waitForCheck()
        check(manager.state.isEntitled, "five days offline")
        check(try store.load()?.lastSeenAt == start.addingTimeInterval(5 * day), "the latest time seen is persisted")

        // Setting the clock back to day 1 would otherwise buy four more offline days.
        clock.set(start.addingTimeInterval(day))
        let relaunched = await makeManager(remote: remote, clock: clock, store: store, auth: auth)
        check(relaunched.state == .needsCheck(yearly()), "a rolled-back clock needs a check")
    }

    @MainActor static func explicitRevoke() async throws {
        let clock = TestClock(start)
        let remote = TestRemote([.entitlement(yearly())])
        let manager = await makeManager(remote: remote, clock: clock, auth: MemoryLicenseAuthStore(session: session()))
        check(manager.state.isEntitled, "entitled before the refund")
        let revoked = Entitlement(active: false, tier: .free, validUntil: nil, memberUntil: nil, yearlyUntil: nil, serverTime: start.addingTimeInterval(60))
        await remote.reply([.entitlement(revoked)])
        clock.advance(60)
        manager.revalidate(force: true, immediately: true)
        await manager.waitForCheck()
        check(manager.state == .notEntitled(revoked), "active:false from the server revokes at once")
        await remote.reply([.failure(.temporarilyUnavailable)])
        manager.revalidate(force: true, immediately: true)
        await manager.waitForCheck()
        check(!manager.state.isEntitled, "a later outage does not restore a revoked membership")
    }

    @MainActor static func loginRequiredRefresh() async throws {
        let clock = TestClock(start)
        let flow = TestAuthFlow()
        let auth = MemoryLicenseAuthStore(session: session(token: "expired-on-server"))
        let remote = TestRemote([.failure(.loginRequired), .entitlement(yearly())])
        let manager = await makeManager(remote: remote, clock: clock, auth: auth, flow: flow)
        check(manager.state.isEntitled, "401 refreshes the token and retries")
        check(flow.refreshes == 1, "exactly one refresh")
        check(await remote.tokens == ["expired-on-server", "refreshed-1"], "the retry uses the new token")
        check(try auth.load()?.accessToken == "refreshed-1", "the refreshed session is saved")

        // Still 401 after the refresh: signed out, cache cleared.
        let store = MemoryEntitlementStore()
        let stuckAuth = MemoryLicenseAuthStore(session: session())
        let stuck = TestRemote([.entitlement(yearly())])
        _ = await makeManager(remote: stuck, clock: clock, store: store, auth: stuckAuth)
        await stuck.reply([.failure(.loginRequired)])
        let stuckFlow = TestAuthFlow()
        let relaunched = await makeManager(remote: stuck, clock: clock, store: store, auth: stuckAuth, flow: stuckFlow)
        check(relaunched.state == .signedOut, "401 twice signs out")
        check(stuckFlow.refreshes == 1, "only one retry")
        check(try store.load() == nil && (try stuckAuth.load()) == nil, "signing out clears the cache and session")

        // A refused refresh token also signs out.
        let refusedFlow = TestAuthFlow()
        refusedFlow.refreshOutcome(.rejected)
        let refused = await makeManager(remote: TestRemote([.failure(.loginRequired)]), clock: clock, auth: MemoryLicenseAuthStore(session: session()), flow: refusedFlow)
        check(refused.state == .signedOut, "a revoked refresh token signs out")

        // The token service being down is an outage, not a sign-out.
        let outageStore = MemoryEntitlementStore()
        let outageAuth = MemoryLicenseAuthStore(session: session())
        let outage = TestRemote([.entitlement(yearly())])
        _ = await makeManager(remote: outage, clock: clock, store: outageStore, auth: outageAuth)
        await outage.reply([.failure(.loginRequired)])
        let outageFlow = TestAuthFlow()
        outageFlow.refreshOutcome(.outage)
        let kept = await makeManager(remote: outage, clock: clock, store: outageStore, auth: outageAuth, flow: outageFlow)
        check(kept.state.isEntitled && kept.lastCheckFailed, "a refresh outage keeps the cached state")
    }

    @MainActor static func accountChanges() async throws {
        let clock = TestClock(start)
        let store = MemoryEntitlementStore()
        let auth = MemoryLicenseAuthStore(session: session())
        let remote = TestRemote([.entitlement(yearly())])
        let manager = await makeManager(remote: remote, clock: clock, store: store, auth: auth)
        await manager.signOut()
        check(manager.state == .signedOut, "sign out closes the gate")
        check(try store.load() == nil, "sign out clears the cache")

        // A cache left by another account is never used.
        let other = EntitlementCache(userID: UUID(), entitlement: yearly(), checkedAt: start, lastSeenAt: start)
        await remote.reply([.failure(.temporarilyUnavailable)])
        let switched = await makeManager(remote: remote, clock: clock, store: MemoryEntitlementStore(other), auth: MemoryLicenseAuthStore(session: session()))
        check(!switched.state.isEntitled, "another account's cache does not unlock")
    }

    @MainActor static func wireClient() async throws {
        let body = #"{"ok":true,"product":"transeen","required_tier":"yearly","active":true,"valid_until":"2027-11-05T10:20:24.968123+00:00","tier":"yearly","member_until":"2027-11-05T10:20:24.968123+00:00","yearly_until":"2027-11-05T10:20:24.968123+00:00","early_bird":false,"server_time":"2026-11-05T10:20:24.1+00:00"}"#
        let configuration = LicenseRemoteConfiguration(
            supabaseURL: URL(string: "https://example.supabase.co"), publishableKey: "sb_publishable_test",
            entitlementURL: URL(string: "https://itool.tech/api/membership/entitlement"), appVersion: "test")

        let website = MembershipEntitlementClient(configuration: configuration, transport: TestTransport { request in
            check(request.url?.absoluteString == "https://itool.tech/api/membership/entitlement?product=transeen", "website URL")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc", "bearer token")
            return (200, body)
        })
        let parsed = try await website.entitlement(accessToken: "abc")
        check(parsed.active && parsed.tier == .yearly && parsed.requiredTier == .yearly, "fields parsed")
        check(abs(parsed.validUntil!.timeIntervalSince1970 - 1_825_410_024.968) < 0.01, "microsecond dates parsed")
        check(abs(parsed.serverTime.timeIntervalSince1970 - 1_793_874_024.1) < 0.01, "short fractions parsed")

        let fallback = MembershipEntitlementClient(configuration: configuration, transport: TestTransport { request in
            if request.url?.host == "itool.tech" { return (503, #"{"ok":false,"code":"temporarily_unavailable"}"#) }
            check(request.url?.absoluteString == "https://example.supabase.co/rest/v1/rpc/itool_entitlement", "RPC URL")
            check(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test", "RPC headers")
            let sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
            check(sent == ["p_product": "transeen"], "RPC body")
            return (200, body)
        })
        check(try await fallback.entitlement(accessToken: "abc").active, "a website outage falls back to Supabase")

        let unauthorized = MembershipEntitlementClient(configuration: configuration, transport: TestTransport { request in
            check(request.url?.host == "itool.tech", "401 does not fall back")
            return (401, #"{"ok":false,"code":"login_required"}"#)
        })
        do { _ = try await unauthorized.entitlement(accessToken: "abc"); fatalError("FAILED: 401 must throw") }
        catch EntitlementServiceError.loginRequired {}

        let offline = MembershipEntitlementClient(configuration: configuration, transport: TestTransport { _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await offline.entitlement(accessToken: "abc"); fatalError("FAILED: offline must throw") }
        catch EntitlementServiceError.temporarilyUnavailable {}

        let wrongProduct = MembershipEntitlementClient(configuration: configuration, transport: TestTransport { _ in
            (200, body.replacingOccurrences(of: #""product":"transeen""#, with: #""product":"stupidmirror""#))
        })
        do { _ = try await wrongProduct.entitlement(accessToken: "abc"); fatalError("FAILED: another product's answer must be refused") }
        catch {}
    }

    /// Signing out of Transeen ends only this sign-in; itool.tech and the other iTool apps stay
    /// signed in. Without `scope=local` Supabase ends every session of the account.
    static func signOutIsLocal() async throws {
        let seen = SeenRequests()
        let transport = TestTransport { request in seen.add(request); return (204, "") }
        let configuration = LicenseRemoteConfiguration(
            supabaseURL: URL(string: "https://example.supabase.co"), publishableKey: "sb_publishable_x",
            entitlementURL: nil, appVersion: "test")
        await SupabaseLicenseAuthClient(configuration: configuration, transport: transport).signOut(session(token: "jwt"))
        let request = seen.all.first
        check(request?.httpMethod == "POST", "sign-out posts")
        check(request?.url?.path == "/auth/v1/logout", "sign-out path")
        check(URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "scope", value: "local")) == true, "sign-out is scope=local")
        check(request?.value(forHTTPHeaderField: "Authorization") == "Bearer jwt", "sign-out sends the session")
        print("sign-out scope local: ok")
    }

    /// GitHub / Google sign-in opens a tab in the person's browser and waits on a loopback
    /// listener (LoopbackOAuth.swift). Here a URLSession request stands in for the browser.
    static func loopbackOAuth() async throws {
        let auth = URL(string: "https://example.supabase.co/auth/v1")!
        let built = SupabaseLicenseAuthClient.authorizeURL(
            authBase: auth, provider: .github, redirect: URL(string: "http://127.0.0.1:5555/linkshell/callback")!,
            challenge: "abc", publishableKey: "sb_publishable_x")
        let query = URLComponents(url: built, resolvingAgainstBaseURL: false)!.queryItems!
        let value = { (name: String) in query.first { $0.name == name }?.value }
        check(built.path == "/auth/v1/authorize", "authorize path")
        check(value("redirect_to") == "http://127.0.0.1:5555/linkshell/callback", "loopback redirect")
        check(value("code_challenge_method") == "s256" && value("code_challenge") == "abc", "PKCE challenge")
        check(value("scopes") == "read:user user:email", "GitHub email scope")

        func visit(_ suffix: String) async throws -> (URL, String) {
            let opened = OpenedURL()
            let task = Task {
                try await LoopbackOAuth.run(productName: "Transeen", timeout: 10, open: { opened.set($0) }) { redirect in
                    URL(string: "https://example.test/authorize?redirect_to=\(redirect.absoluteString)")!
                }
            }
            let authorize = try await opened.wait()
            let redirect = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_to" }!.value!
            check(redirect.hasPrefix("http://127.0.0.1:") && redirect.hasSuffix("/linkshell/callback"), "listener on loopback")
            let (missing, notFound) = try await URLSession.shared.data(from: URL(string: redirect.replacingOccurrences(of: "/linkshell/callback", with: "/other"))!)
            check((notFound as? HTTPURLResponse)?.statusCode == 404 && missing.isEmpty, "other paths 404")
            let (body, response) = try await URLSession.shared.data(from: URL(string: redirect + suffix)!)
            check((response as? HTTPURLResponse)?.statusCode == 200, "callback page served")
            return (try await task.value, String(decoding: body, as: UTF8.self))
        }

        let (ok, okPage) = try await visit("?code=one-time")
        check(try SupabaseLicenseAuthClient.authCode(from: ok) == "one-time", "code delivered")
        check(okPage.contains("已完成授权"), "success page")

        let (denied, _) = try await visit("?error=access_denied&error_description=nope")
        do { _ = try SupabaseLicenseAuthClient.authCode(from: denied); fatalError("FAILED: denial must throw") }
        catch LicenseAuthError.cancelled {}

        let (failed, _) = try await visit("?error_code=bad_oauth_state&error_description=State%20expired")
        do { _ = try SupabaseLicenseAuthClient.authCode(from: failed); fatalError("FAILED: error_code must throw") }
        catch let LicenseAuthError.rejected(message) { check(message == "State expired", "provider message kept") }

        // Nothing comes back: it gives up on its own.
        do {
            _ = try await LoopbackOAuth.run(productName: "Transeen", timeout: 0.3, open: { _ in }) { $0 }
            fatalError("FAILED: must time out")
        } catch LoopbackOAuthError.timedOut {}

        // Cancelling the sign-in (closing the panel) ends the wait.
        let waiting = Task { try await LoopbackOAuth.run(productName: "Transeen", timeout: 10, open: { _ in }) { $0 } }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        do { _ = try await waiting.value; fatalError("FAILED: must cancel") }
        catch LoopbackOAuthError.cancelled {}
        print("loopback oauth: ok")
    }
}

final class OpenedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func set(_ url: URL) { lock.withLock { self.url = url } }
    func wait() async throws -> URL {
        for _ in 0..<200 {
            let url = lock.withLock { self.url }
            if let url { return url }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("FAILED: the browser was never opened")
    }
}

final class SeenRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    var all: [URLRequest] { lock.withLock { requests } }
}
