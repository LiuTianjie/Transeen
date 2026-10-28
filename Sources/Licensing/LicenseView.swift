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
                    Text(manager.state.isActivated ? "Transeen 已激活" : "激活 Transeen").font(.title2.weight(.semibold))
                    Text("让译文留在原处").foregroundStyle(.secondary)
                }
            }
            if manager.state.isActivated {
                Label("永久授权 · 截图、标注与翻译已解锁", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text("输入 Transeen 专用激活码，解锁截图、标注和翻译。无需登录即可激活这台 Mac。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("TR-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $code)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .disabled(busy).onSubmit(activate)
                HStack {
                    Link("获取激活码", destination: LicensePurchaseLinks.buyURL)
                    Spacer()
                    Button(manager.isActivating ? "正在激活…" : "激活这台 Mac", action: activate)
                        .buttonStyle(.borderedProminent).disabled(busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if case .unavailable(let reason) = manager.state { Text(reason).font(.caption).foregroundStyle(.red) }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            DisclosureGroup("iTool 账号 · 可选的绑定与恢复") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("TR- 授权独立于 iTool Pro 和 StupidMirror。绑定账号后，可登录同一账号恢复授权。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let session = manager.authSession {
                        Text(session.email ?? "已登录 iTool 账号").font(.callout)
                        HStack {
                            if manager.needsClaim {
                                Button("将本机授权绑定到账号") { run { try await manager.claimFromReceipt() } }
                            }
                            Button("恢复授权") { run { manager.validateInBackgroundIfNeeded(force: true); await manager.waitForBackgroundValidation(); message = manager.state.isActivated ? "授权已恢复。" : "此账号尚未绑定 Transeen 授权。" } }
                            Spacer()
                            Button("退出账号") { Task { await manager.signOut() } }
                        }
                    } else {
                        HStack {
                            Button("使用 Google 登录") { run { try await manager.signIn(provider: .google) } }
                            Button("使用 GitHub 登录") { run { try await manager.signIn(provider: .github) } }
                        }
                        TextField("邮箱", text: $email).textFieldStyle(.roundedBorder)
                        SecureField("密码", text: $password).textFieldStyle(.roundedBorder)
                        Button("使用邮箱登录") { run { try await manager.signIn(email: email, password: password); password = "" } }
                            .disabled(email.isEmpty || password.isEmpty)
                    }
                }.padding(.top, 12).disabled(busy)
            }
            HStack {
                Text("授权信息安全保存在 macOS 钥匙串中").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(manager.state.isActivated ? "开始使用" : "稍后", action: done).disabled(busy)
            }
        }.padding(26).frame(width: 500).fixedSize(horizontal: false, vertical: true)
    }
    private func activate() { run { try await manager.activate(code: code); code = ""; message = "激活成功。" } }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        message = nil
        Task { @MainActor in
            do { try await action() } catch { message = error.localizedDescription }
        }
    }
}
