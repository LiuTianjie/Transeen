import Foundation

final class TestLicenseStore: LicenseRecordStoring, @unchecked Sendable {
    let lock = NSLock()
    private var value: LocalLicenseRecord?
    init(_ value: LocalLicenseRecord? = nil) { self.value = value }
    func load() throws -> LocalLicenseRecord? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ record: LocalLicenseRecord) throws { lock.lock(); defer { lock.unlock() }; value = record }
}
actor TestLicenseRemote: LicenseRemoteServicing {
    let receipt = UUID().uuidString
    var rejection: String?
    func reject(_ code: String?) { rejection = code }
    func activate(code: String, installationID: UUID) async throws -> LicenseActivation { LicenseActivation(receipt: receipt, serverTime: Date()) }
    func validate(receipt: String, installationID: UUID) async throws -> LicenseValidation {
        if let rejection { throw LicenseServiceError.rejected(code: rejection, message: rejection) }
        return LicenseValidation(isValid: true, refreshedReceipt: receipt, serverTime: Date())
    }
    func redeem(code: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation { try await activate(code: code, installationID: installationID) }
    func claim(receipt: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation { LicenseActivation(receipt: receipt, serverTime: Date()) }
    func validateAccount(installationID: UUID, accessToken: String) async throws -> LicenseValidation { try await validate(receipt: receipt, installationID: installationID) }
}
@main struct LicenseTests {
    @MainActor static func main() async throws {
        let store = TestLicenseStore(), remote = TestLicenseRemote()
        let manager = LicenseManager(store: store, remote: remote)
        await manager.bootstrap()
        precondition(!manager.state.isActivated)
        let code = "TR-2345-6789-ABCD-EFGH-JKLM-NPQR"
        precondition(LicenseManager.isTranseenCode(code.lowercased()))
        for invalid in [code.replacingOccurrences(of: "TR", with: "SM"), code.replacingOccurrences(of: "TR", with: "IT"), code + "!", "TR-0000"] {
            do { try await manager.activate(code: invalid); preconditionFailure("Wrong product activated") } catch {}
        }
        try await manager.activate(code: code)
        precondition(manager.state.isActivated)
        let restarted = LicenseManager(store: store, remote: remote)
        await restarted.bootstrap()
        precondition(restarted.state.isActivated)
        await remote.reject("temporarily_unavailable")
        restarted.validateInBackgroundIfNeeded(force: true); await restarted.waitForBackgroundValidation()
        precondition(restarted.state.isActivated, "Network failure must preserve a cached activation")
        await remote.reject("invalid_receipt")
        restarted.validateInBackgroundIfNeeded(force: true); await restarted.waitForBackgroundValidation()
        precondition(!restarted.state.isActivated, "Explicit revocation must close the gate")
        var record = LocalLicenseRecord(); record.activationReceipt = UUID().uuidString; record.licensePrincipal = .account; record.claimedUserID = UUID(); record.lastValidatedAt = Date()
        let wrongSession = LicenseAuthSession(userID: UUID(), accessToken: "test", refreshToken: "test", expiresAt: Date().addingTimeInterval(3600))
        let account = LicenseManager(store: TestLicenseStore(record), remote: remote, authStore: MemoryLicenseAuthStore(session: wrongSession))
        await account.bootstrap()
        precondition(!account.state.isActivated, "A different account must not reuse a cached entitlement")
        precondition(ReleaseVersion("v0.10.0")! > ReleaseVersion("0.9.9")!)
        precondition(ReleaseVersion("0.7") == ReleaseVersion("0.7.0"))
        precondition(ReleaseVersion("0.7.0-beta") == nil)
        print("License lifecycle, product isolation, revocation, account ownership, and update version checks passed")
    }
}
