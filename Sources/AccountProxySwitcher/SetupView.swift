import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var networkMessage: String?
    @State private var browserMessage: String?
    @State private var upstreamURL = ""
    @State private var isSavingUpstream = false
    @State private var upstreamMessage: String?

    private var report: EnvironmentSetupReport? { model.setupReport }
    private var isWorking: Bool { model.isBusy || model.isCheckingEnvironment || isSavingUpstream }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("软件设置").font(.system(size: 17, weight: .semibold))
                    Text("为这台 Mac 设置一次，所有账号共用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    networkSettings
                    Divider()
                    browserSettings
                    Divider()
                    advancedSettings
                    diagnosticDetails
                }
                .padding(.trailing, 3)
            }
            .frame(maxHeight: 360)
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                Text("此页不发起账号切换，启用请回主界面。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy || isSavingUpstream)
            }
        }
        .padding(18)
        .frame(width: 500)
        .interactiveDismissDisabled(model.isBusy || isSavingUpstream)
        .task { await model.checkEnvironment() }
    }

    @ViewBuilder
    private var networkSettings: some View {
        if model.usesClashCoexist {
            VStack(alignment: .leading, spacing: 8) {
                settingTitle("与 Clash 共存", ready: model.applicationPrepared)
                Text("沿用你正在使用的 Clash，无需另外安装或重复授权网络服务。只为指定服务添加账号出口，其他网络继续按 Clash 原有设置运行。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Label(model.applicationPrepared ? "已连接 Clash，所有账号共用" : "尚未确认 Clash 连接", systemImage: model.applicationPrepared ? "checkmark.circle.fill" : "info.circle")
                        .font(.caption).foregroundStyle(model.applicationPrepared ? Color.green : Color.orange)
                    Spacer(minLength: 0)
                    Button("重新检查") { Task { await model.checkEnvironment() } }
                }
                .controlSize(.small)
                .disabled(isWorking)
                Text("启用账号时只更新指定服务规则；不重启 Clash、不改系统 DNS，也不清理正在使用的连接。浏览器防泄露在下方单独设置。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            networkPermissionSettings
        }
    }

    private var networkPermissionSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingTitle("允许 ccmiss 管理网络", ready: model.applicationPrepared)
            Text("首次使用时需要你在 macOS 中确认一次，以后切换账号无需重复设置。首次设置不选择账号，完成后回主界面启用。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if model.applicationPrepared {
                    Label("已允许，所有账号可共用", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Spacer(minLength: 0)
                    Button("重新检查") { Task { await model.checkEnvironment() } }
                } else {
                    Text(networkStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if model.serviceAuthorizationState == .requiresApproval {
                        Button("重新检查") { Task { await model.checkEnvironment() } }
                        Button("打开系统授权") { model.openBackgroundServiceSettings() }
                            .buttonStyle(.borderedProminent)
                    } else if model.serviceAuthorizationState == .authorized {
                        Button("重新检查") { Task { await model.checkEnvironment() } }
                    } else {
                        Button("允许管理网络") {
                            networkMessage = nil
                            Task {
                                await model.prepareApplication()
                                networkMessage = model.statusMessage
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .controlSize(.small)
            .disabled(isWorking)
            if let networkMessage, !model.applicationPrepared {
                Text(networkMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let conflict = model.networkConflictSummary {
                Text(conflict).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var networkStatus: String {
        switch model.serviceAuthorizationState {
        case .unknown: return "等待检查"
        case .notInstalled: return "尚未允许"
        case .requiresApproval: return "等待你在系统设置中允许"
        case .authorized: return "已获授权，尚未确认可用"
        case .unavailable: return "暂时无法准备，可重试或查看诊断详情"
        }
    }

    private var browserSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingTitle("浏览器防泄露", ready: model.browserProtectionReady)
            Text("用于限制网页通话绕过代理、暴露真实 IP。所有账号共用，可单独设置。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(model.browserProtectionReady ? "已设置" : "待处理", systemImage: model.browserProtectionReady ? "checkmark.circle.fill" : "info.circle")
                .font(.caption).foregroundStyle(model.browserProtectionReady ? Color.green : Color.orange)
            Text(browserExplanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if report?.requiresBrowserFileAccess == true {
                    Button("打开浏览器权限") { model.openBrowserAccessSettings() }
                }
                Spacer(minLength: 0)
                Button(model.browserProtectionReady ? "重新检查" : "设置浏览器防泄露") {
                    browserMessage = nil
                    Task {
                        if model.browserProtectionReady { await model.checkEnvironment() }
                        else { await model.configureBrowserProtection() }
                        browserMessage = model.statusMessage
                    }
                }
                .disabled(!model.browserProtectionReady && report?.requiresManualWebRTC == true)
            }
            .controlSize(.small)
            .disabled(isWorking)
            if let browserMessage {
                Text(browserMessage).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private var browserExplanation: String {
        if model.browserProtectionReady { return "防泄露设置已保存，可在主界面的检测入口核对浏览器实际结果。" }
        if report?.requiresBrowserFileAccess == true {
            return "需要在 macOS 的“完全磁盘访问权限”中允许 ccmiss，才能修改浏览器配置。你可以先跳过；账号代理仍可启用，浏览器保护则保持待处理。"
        }
        if report?.needsBrowserRestart == true {
            return "请自行完全退出浏览器后，再点击设置；ccmiss 不会替你关闭浏览器。"
        }
        if report?.requiresManualWebRTC == true {
            return "当前浏览器需要手动设置防泄露；你可以先使用账号代理，之后再检查。"
        }
        return "在浏览器关闭时保存防泄露设置，并保留原设置的备份。"
    }

    private var advancedSettings: some View {
        DisclosureGroup("高级设置") {
            VStack(alignment: .leading, spacing: 8) {
                Text("前置连接 · 所有账号共用").font(.system(size: 11, weight: .medium))
                Text(model.upstreamProxySummary)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(model.usesClashCoexist ? "通常无需修改。仅影响账号代理链路，保存后在下次启用账号时生效；其他 Clash 流量保持原样。" : "通常无需填写。只有代理需要额外连接时再设置；保存后在下次启用账号时生效，当前网络保持不变。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("socks5://… 或 vless://…（Reality）", text: $upstreamURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                HStack {
                    if isSavingUpstream { ProgressView().controlSize(.mini) }
                    Spacer()
                    Button("移除前置") { saveUpstream("") }
                    Button("保存前置") { saveUpstream(upstreamURL.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(upstreamURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .controlSize(.small)
                .disabled(isWorking)
                if let upstreamMessage {
                    Text(upstreamMessage).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .padding(.top, 7)
        }
        .font(.system(size: 11))
    }

    private var diagnosticDetails: some View {
        DisclosureGroup("查看诊断详情") {
            VStack(alignment: .leading, spacing: 8) {
                if let diagnostic = model.applicationPreparationDiagnostic {
                    Text(diagnostic).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Text(model.browserProtectionSummary)
                    .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                if let report {
                    ForEach(report.checks) { check in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: checkSymbol(check.state)).foregroundStyle(checkColor(check.state))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.title).font(.system(size: 10, weight: .medium))
                                Text(check.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                    Text(report.message).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Button(model.isCheckingEnvironment ? "检查中…" : "重新检查") { Task { await model.checkEnvironment() } }
                    .controlSize(.small).disabled(isWorking)
            }
            .padding(.top, 7)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func saveUpstream(_ url: String) {
        isSavingUpstream = true
        upstreamMessage = nil
        Task {
            defer { isSavingUpstream = false }
            await model.configureUpstream(url: url)
            upstreamMessage = model.statusMessage
            if url.isEmpty { upstreamURL = "" }
        }
    }

    private func settingTitle(_ title: String, ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ready ? Color.green : Color.primary)
    }

    private func checkSymbol(_ state: SetupCheckState) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .actionRequired: return "exclamationmark.circle.fill"
        case .unavailable: return "xmark.circle.fill"
        case .pending: return "circle.dotted"
        }
    }

    private func checkColor(_ state: SetupCheckState) -> Color {
        switch state {
        case .ready: return .green
        case .actionRequired: return .orange
        case .unavailable, .pending: return .secondary
        }
    }
}
