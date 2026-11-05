import AppKit
import SwiftUI

/// Account and membership: sign in to iTool, see the tier, buy or upgrade, refresh after paying.
struct LicenseView: View {
    @ObservedObject var manager: LicenseManager
    var done: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    @State private var browserSignIn: Task<Void, Never>?
    private var busy: Bool { manager.isSigningIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("账号与会员")).font(.title2.weight(.semibold))
                    Text(L("Transeen 包含在 iTool 年度会员中")).foregroundStyle(.secondary)
                }
            }
            if browserSignIn != nil {
                waitingForBrowser
            } else if manager.authSession == nil {
                signInForm
            } else {
                membership
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Text(L("登录信息安全保存在 macOS 钥匙串中")).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(manager.state.isEntitled ? L("开始使用") : L("稍后"), action: done).disabled(busy)
            }
        }
        // Coming back from the browser after paying re-checks: AppDelegate revalidates on activation.
        .padding(26).frame(width: 500).fixedSize(horizontal: false, vertical: true).settingsSurface()
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("截图、标注、导入图片和翻译需要登录 iTool 账号，并拥有 iTool 年度会员。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("使用 Google 登录")) { signInInBrowser(.google) }
                Button(L("使用 GitHub 登录")) { signInInBrowser(.github) }
            }
            TextField(L("邮箱"), text: $email).textFieldStyle(.roundedBorder)
            SecureField(L("密码"), text: $password).textFieldStyle(.roundedBorder).onSubmit(signInWithEmail)
            HStack {
                Button(manager.isSigningIn ? L("正在登录…") : L("使用邮箱登录"), action: signInWithEmail)
                    .disabled(email.isEmpty || password.isEmpty)
                Spacer()
                Link(L("开通 iTool 年度会员 (¥99/年，含全部 iTool 产品)"), destination: LicensePurchaseLinks.membershipURL())
                    .font(.callout)
            }
        }.disabled(busy)
    }

    @ViewBuilder private var membership: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(manager.authSession?.email ?? L("已登录 iTool 账号"), systemImage: "person.crop.circle")
                    .font(.callout)
                Spacer()
                Button(L("退出账号")) { Task { await manager.signOut() } }.controlSize(.small)
            }
            status
            HStack {
                if !manager.state.isEntitled {
                    Button(upgradeTitle) { NSWorkspace.shared.open(LicensePurchaseLinks.membershipURL()) }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button(manager.isChecking ? L("正在刷新…") : L("刷新会员状态")) {
                    run {
                        await manager.refreshMembership()
                        if manager.lastCheckFailed { message = L("暂时无法连接 iTool，请稍后再试。") }
                    }
                }.disabled(manager.isChecking)
            }
        }
    }

    @ViewBuilder private var status: some View {
        let entitlement = manager.state.entitlement
        switch manager.state {
        case .entitled:
            Label(L("iTool 年度会员 · 截图、标注与翻译已解锁"), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            if let until = entitlement?.validUntil {
                detail(L("有效期至 %@", Self.day(until)))
            }
            if manager.lastCheckFailed, let offline = manager.offlineUntil {
                detail(L("暂时无法连接 iTool，离线可用至 %@", Self.day(offline)))
            }
        case .notEntitled:
            if entitlement?.tier == .monthly {
                Label(L("当前为 iTool 月度会员"), systemImage: "person.badge.clock")
                if let until = entitlement?.memberUntil { detail(L("有效期至 %@", Self.day(until))) }
                detail(L("月度会员包含 iTool 网站和 LinkShell。Transeen 需要 iTool 年度会员。"))
            } else {
                Label(L("此账号还没有 iTool 会员"), systemImage: "person.crop.circle.badge.questionmark")
                detail(L("iTool 年度会员 ¥99/年，包含 Transeen 和全部 iTool 产品。付款后回到这里刷新会员状态。"))
            }
        case .needsCheck:
            Label(L("需要联网确认会员状态"), systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
            detail(L("离线使用最多 7 天。连接网络后刷新会员状态即可继续使用。"))
        case .checking, .signedOut:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("正在确认会员状态…")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var upgradeTitle: String {
        manager.state.entitlement?.tier == .monthly ? L("升级年度会员") : L("开通 iTool 年度会员")
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(InterfaceLanguage.shared.locale))
    }

    private var waitingForBrowser: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L("请在浏览器中完成登录")).font(.callout)
            Spacer()
            Button(L("取消")) { browserSignIn?.cancel() }
        }
    }

    /// The sign-in page opens as a tab in the default browser; this panel waits and can cancel.
    private func signInInBrowser(_ provider: LicenseAuthProvider) {
        message = nil
        browserSignIn = Task { @MainActor in
            defer { browserSignIn = nil }
            do { try await manager.signIn(provider: provider) } catch LicenseAuthError.cancelled {
            } catch is CancellationError {
            } catch { message = error.localizedDescription }
        }
    }

    private func signInWithEmail() {
        guard !email.isEmpty, !password.isEmpty else { return }
        run { try await manager.signIn(email: email, password: password); password = "" }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        message = nil
        Task { @MainActor in
            do { try await action() } catch LicenseAuthError.cancelled {
            } catch { message = error.localizedDescription }
        }
    }
}
