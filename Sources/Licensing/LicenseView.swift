import AppKit
import SwiftUI

struct LicenseView: View {
    @ObservedObject var manager: LicenseManager
    var done: () -> Void
    @State private var code = ""
    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    private var busy: Bool { manager.isActivating || manager.isSigningIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable().frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(manager.state.isActivated ? L("Transeen 已激活") : L("激活 Transeen")).font(.title2.weight(.semibold))
                    Text(L("让译文留在原处")).foregroundStyle(.secondary)
                }
            }
            if manager.state.isActivated {
                Label(L("永久授权 · 截图、标注与翻译已解锁"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text(L("输入 Transeen 专用激活码，解锁截图、标注和翻译。无需登录即可激活这台 Mac。"))
                    .font(.callout).foregroundStyle(.secondary)
                TextField("TR-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $code)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .disabled(busy).onSubmit(activate)
                HStack {
                    Link(L("获取激活码"), destination: LicensePurchaseLinks.buyURL)
                    Spacer()
                    Button(manager.isActivating ? L("正在激活…") : L("激活这台 Mac"), action: activate)
                        .buttonStyle(.borderedProminent).disabled(busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if case .unavailable(let reason) = manager.state { Text(reason).font(.caption).foregroundStyle(.red) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            DisclosureGroup(L("iTool 账号 · 可选的绑定与恢复")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("TR- 授权独立于 iTool Pro 和 StupidMirror。绑定账号后，可登录同一账号恢复授权。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let session = manager.authSession {
                        Text(session.email ?? L("已登录 iTool 账号")).font(.callout)
                        HStack {
                            if manager.needsClaim {
                                Button(L("将本机授权绑定到账号")) { run { try await manager.claimFromReceipt() } }
                            }
                            Button(L("恢复授权")) { run { manager.validateInBackgroundIfNeeded(force: true); await manager.waitForBackgroundValidation(); message = manager.state.isActivated ? L("授权已恢复。") : L("此账号尚未绑定 Transeen 授权。") } }
                            Spacer()
                            Button(L("退出账号")) { Task { await manager.signOut() } }
                        }
                    } else {
                        HStack {
                            Button(L("使用 Google 登录")) { run { try await manager.signIn(provider: .google) } }
                            Button(L("使用 GitHub 登录")) { run { try await manager.signIn(provider: .github) } }
                        }
                        TextField(L("邮箱"), text: $email).textFieldStyle(.roundedBorder)
                        SecureField(L("密码"), text: $password).textFieldStyle(.roundedBorder)
                        Button(L("使用邮箱登录")) { run { try await manager.signIn(email: email, password: password); password = "" } }
                            .disabled(email.isEmpty || password.isEmpty)
                    }
                }.padding(.top, 12).disabled(busy)
            }
            HStack {
                Text(L("授权信息安全保存在 macOS 钥匙串中")).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(manager.state.isActivated ? L("开始使用") : L("稍后"), action: done).disabled(busy)
            }
        }.padding(26).frame(width: 500).fixedSize(horizontal: false, vertical: true)
    }
    private func activate() { run { try await manager.activate(code: code); code = ""; message = L("激活成功。") } }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        message = nil
        Task { @MainActor in
            do { try await action() } catch { message = error.localizedDescription }
        }
    }
}
