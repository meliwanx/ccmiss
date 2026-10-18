import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var editor: ProfileEditorRequest?
    @State private var pendingDeletion: ProxyProfile?
    @State private var localError: String?
    @State private var showCredentials = false
    @State private var showEnvironmentSetup = false
    @State private var showClaudeTools = false
    @StateObject private var claudeTools = ClaudeToolsModel.shared

    private var selectedProfile: ProxyProfile? {
        model.profiles.first { $0.id == model.selectedProfileID }
    }

    private var activeProfile: ProxyProfile? {
        guard model.isProxyModeKnown, model.proxyMode == .profile else { return nil }
        return model.profiles.first { $0.id == model.activeProfileID }
    }

    private var visibleVerification: ExitVerification? {
        model.currentVerification
    }

    private var isFollowingSystem: Bool {
        model.isProxyModeKnown && model.proxyMode == .system && !model.proxyModeNeedsAttention
    }

    private var systemModeHelp: String {
        model.usesClashCoexist ? "移除 ccmiss 的账号出口覆盖，继续使用 Clash 原有规则；账号配置会保留" : "停用账号配置，继续使用系统当前网络；账号配置会保留"
    }

    private var systemModeStatus: String {
        model.usesClashCoexist ? "未启用账号覆盖，网络继续按 Clash 原有设置运行。" : "正在使用系统网络；你可以选择账号后启用配置。"
    }

    private var operationStatus: String {
        if model.isBusy { return model.statusMessage.isEmpty ? "正在处理网络设置，请稍候。" : model.statusMessage }
        if let notice = model.activationNotice { return notice.message }
        if isFollowingSystem { return systemModeStatus }
        if model.engineStatus.isOperational, let active = activeProfile {
            return model.usesClashCoexist ? "指定服务正在使用“\(active.name)”，其他网络继续沿用 Clash。" : "正在使用“\(active.name)”。"
        }
        return model.activationReadiness.summary
    }

    private var currentNetworkTitle: String {
        if model.isBusy { return "正在更新网络…" }
        if isFollowingSystem { return "使用系统网络" }
        if model.engineStatus.isOperational, !model.proxyModeNeedsAttention, let active = activeProfile {
            return "账号：\(active.name)"
        }
        return "网络状态待检查"
    }

    private var needsGlobalRestore: Bool {
        guard !isFollowingSystem else { return false }
        guard let selectedProfile else { return true }
        return model.accountNetworkAction(for: selectedProfile) != .stop
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 680, minHeight: 340)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showClaudeTools = true } label: {
                    Label("Claude Code 工具", systemImage: "wrench.and.screwdriver")
                }
                .help("Claude Code 状态、对话备份与安装维护")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await model.refreshStatus() }
                } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .help("检查当前网络和出口状态")
                .disabled(model.isBusy)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .new
                } label: {
                    Label("添加账号配置", systemImage: "plus")
                }
                .help("添加一个 SOCKS5 代理和对应账号")
                .disabled(model.isBusy)
            }
        }
        .sheet(item: $editor) { request in
            ProfileEditor(model: model, request: request)
        }
        .sheet(isPresented: $showEnvironmentSetup) {
            SetupView(model: model)
        }
        .sheet(isPresented: $showClaudeTools) {
            ClaudeToolsView(model: claudeTools)
        }
        .alert("删除账号配置？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) {
                guard let profile = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    do { try await model.deleteProfile(profile) }
                    catch { localError = error.localizedDescription }
                }
            }
        } message: {
            Text("将删除“\(pendingDeletion?.name ?? "")”及其保存的代理凭证。")
        }
        .alert("操作未完成", isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button("好", role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "")
        }
        .onAppear { model.startStatusMonitoring() }
        .onDisappear { model.stopStatusMonitoring() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            networkSummary
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "person.2").foregroundStyle(.secondary)
                Text("账号配置").font(.system(size: 12, weight: .semibold))
                Text("\(model.profiles.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)

            if model.profiles.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "person.crop.rectangle.badge.plus")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("还没有账号配置").font(.headline)
                    Button("添加第一个配置") { editor = .new }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.profiles) { profile in
                        Button { model.selectedProfileID = profile.id } label: {
                            ProfileSidebarRow(
                                profile: profile,
                                isSelected: profile.id == model.selectedProfileID,
                                isActive: model.isProxyModeKnown && model.proxyMode == .profile && profile.id == model.activeProfileID,
                                isOperational: model.engineStatus.isOperational && !model.proxyModeNeedsAttention
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(profile.id == model.selectedProfileID ? Color.accentColor.opacity(0.12) : Color.clear)
                        .accessibilityValue(profile.id == model.selectedProfileID ? "已选中，右侧操作：\(model.accountNetworkAction(for: profile).title)" : "未选中")
                        .contextMenu {
                            Button(model.accountNetworkAction(for: profile).title) { performAccountAction(profile) }
                                .disabled(model.isBusy || model.isCheckingEnvironment)
                            Button("编辑配置") { edit(profile) }
                                .disabled(model.isBusy)
                            Button("复制代理链接") { copy(profile) }
                            Divider()
                            Button("删除配置", role: .destructive) { pendingDeletion = profile }
                                .disabled(model.isBusy || profile.id == model.activeProfileID)
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack {
                Button { showEnvironmentSetup = true } label: {
                    Label("软件设置", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(model.isBusy)
                Spacer()
            }
            .padding(11)
        }
    }

    private var detail: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let profile = selectedProfile {
                        profileCard(profile).id(profile.id)
                    } else {
                        emptySelectionCard
                    }
                    activationNoticeCard.id("activationNotice")
                    if model.isBusy {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(operationStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if model.activationNotice == nil && (!model.isProxyModeKnown || model.proxyModeNeedsAttention) {
                        Text(operationStatus).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    browserChecksSection
                    configurationDetails
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.activationNotice?.message) { message in
                if message != nil { withAnimation { scroll.scrollTo("activationNotice", anchor: .center) } }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("ccmiss")
        .onChange(of: model.selectedProfileID) { _ in showCredentials = false }
    }

    private var environmentSetupSummary: String {
        if model.usesClashCoexist {
            return model.applicationPrepared ? "与 Clash 共存 · 仅指定服务" : "与 Clash 共存 · 等待检查连接"
        }
        if model.applicationPrepared { return "软件已准备好 · 所有账号共用" }
        switch model.serviceAuthorizationState {
        case .notInstalled:
            return isFollowingSystem ? "使用系统网络 · 启用账号前需一次授权" : "启用账号前需一次软件授权"
        case .requiresApproval: return "等待 macOS 允许 · 请查看软件设置"
        case .authorized: return "已获授权 · 网络功能暂未响应"
        case .unknown, .unavailable: return "软件设置待检查"
        }
    }

    private var networkSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(exitPanelColor)
                    .frame(width: 6, height: 6)
                Text(currentNetworkTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .help(currentNetworkTitle)
                    .accessibilityIdentifier("current-network-summary")
                Spacer(minLength: 0)
            }
            HStack {
                Text("Claude 出口 IP").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Button { model.refreshClaudeExit() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(model.claudeExitError ?? "新建连接，实测 Claude 收到的 IP")
                .accessibilityLabel("重新检测 Claude 出口 IP")
                .disabled(model.isBusy || model.isCheckingEnvironment || model.isCheckingClaudeExit)
            }
            if let observation = model.claudeExitObservation {
                Text(observation.ip)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(model.claudeExitMismatch ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .id(observation.ip)
                    .accessibilityIdentifier("current-claude-exit-ip")
                HStack(spacing: 3) {
                    Text(observation.checkedAt, format: .dateTime.hour().minute().second())
                    if model.claudeExitMismatch {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text("出口异常").foregroundStyle(.red)
                    } else {
                        Text("· 新连接实测")
                    }
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .help(model.claudeExitMismatch ? "实际请求的出口与当前账号验证的 IP 不一致，请重新检测并检查网络设置。" : "向 claude.ai 新建 HTTPS 请求实测，每分钟更新。浏览器单独配置的代理、扩展及切换前的已有连接可能使用不同出口。")
            } else {
                HStack(spacing: 5) {
                    if model.isCheckingClaudeExit { ProgressView().controlSize(.mini) }
                    Text(model.isBusy ? "等待网络操作完成" : model.isCheckingClaudeExit ? "检测中…" : model.claudeExitError == nil ? "未检测" : "未测得")
                        .font(.system(size: 11))
                        .foregroundStyle(model.claudeExitError == nil ? Color.secondary : Color.orange)
                }
                .help(model.claudeExitError ?? "检测结果来自当前系统网络的实际请求，未检测时不会使用配置地址代替。")
                .accessibilityIdentifier("current-claude-exit-pending")
            }
            Label(exitPanelStatus, systemImage: model.claudeExitMismatch ? "exclamationmark.circle.fill" : isExitConfirmed ? "checkmark.circle.fill" : "questionmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(exitPanelColor)
                .help(model.claudeExitMismatch ? "实测出口与当前账号验证的 IP 不一致。" : "显示出口连接状态，不进行 IP 信誉质检。")
                .accessibilityIdentifier("current-exit-status")
            if needsGlobalRestore {
                Button("恢复系统网络") { Task { await model.followSystemProxy() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(systemModeHelp)
                    .disabled(model.isBusy || model.isCheckingEnvironment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(exitPanelColor.opacity(isExitConfirmed || model.claudeExitMismatch ? 0.12 : 0.05))
        .overlay(alignment: .leading) {
            Rectangle().fill(exitPanelColor.opacity(0.7)).frame(width: 3)
        }
    }

    private var isExitConfirmed: Bool {
        guard !model.isBusy, model.isProxyModeKnown, !model.proxyModeNeedsAttention,
              model.claudeExitObservation != nil else { return false }
        return isFollowingSystem || model.claudeExitMatchesAccount
    }

    private var exitPanelStatus: String {
        if model.claudeExitMismatch { return "出口与账号不符" }
        if isExitConfirmed { return isFollowingSystem ? "当前出口已测得" : "账号出口一致" }
        return "等待出口确认"
    }

    private var exitPanelColor: Color {
        if model.claudeExitMismatch { return .red }
        return isExitConfirmed ? .green : .secondary
    }

    private func profileCard(_ profile: ProxyProfile) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).font(.system(size: 18, weight: .semibold)).lineLimit(1).help(profile.name)
                    if !profile.accountDescription.isEmpty && profile.accountDescription != profile.name {
                        Text(profile.accountDescription).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(1).help(profile.accountDescription)
                    }
                }
                Spacer()
                Button { edit(profile) } label: { Image(systemName: "pencil") }
                    .help("编辑账号和代理")
                    .disabled(model.isBusy)
                Menu {
                    if model.accountNetworkAction(for: profile) == .stop || model.engineStatus.needsReapply || model.proxyModeNeedsAttention {
                        Button("重新应用配置") {
                            Task { await model.activateProfile(profile, reapply: true) }
                        }
                    }
                    Button("复制完整代理链接") { copy(profile) }
                    Button("删除配置", role: .destructive) { pendingDeletion = profile }
                        .disabled(profile.id == model.activeProfileID)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.isBusy)
            }
            HStack(spacing: 7) {
                Text(profile.endpoint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle).help(profile.endpoint)
                Text("SOCKS5").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 0)
            }
            if showCredentials {
                Text(credentialText(for: profile))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button {
                    showCredentials.toggle()
                } label: {
                    Label(showCredentials ? "隐藏链接" : "代理链接", systemImage: showCredentials ? "eye.slash" : "eye")
                }
                .buttonStyle(.link)
                .font(.caption)
                Button { copy(profile) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("复制完整代理链接")
                Spacer()
                Button {
                    performAccountAction(profile)
                } label: {
                    Label(model.accountNetworkAction(for: profile).title, systemImage: model.accountNetworkAction(for: profile).symbol)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.accountNetworkAction(for: profile) == .stop ? Color.orange : Color.accentColor)
                .controlSize(.regular)
                .help(model.accountNetworkAction(for: profile) == .stop ? systemModeHelp : "\(model.accountNetworkAction(for: profile).title)：\(profile.name)")
                .accessibilityIdentifier("account-network-action")
                .disabled(model.isBusy || model.isCheckingEnvironment)
            }
        }
        .cardStyle()
    }

    private var emptySelectionCard: some View {
        VStack(spacing: 8) {
            Text(model.profiles.isEmpty ? "从添加账号开始" : "在左侧选择一个账号")
                .font(.subheadline)
            if model.profiles.isEmpty {
                Button("添加账号配置") { editor = .new }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .cardStyle()
    }

    private var configurationDetails: some View {
        DisclosureGroup("详情") {
            VStack(alignment: .leading, spacing: 9) {
                Text(environmentSetupSummary)
                if model.usesClashCoexist {
                    Text("Claude、Cloudflare 和 Stripe 使用账号出口，其他网络沿用原设置。")
                } else {
                    Picker("代理范围", selection: $model.routingScope) {
                        ForEach(RoutingScope.allCases) { scope in Text(scope.title).tag(scope) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isBusy)
                    Text(model.routingScope.explanation)
                }
                Text(model.usesClashCoexist ? "切换只影响新连接；现有连接继续原出口。" : "更改网络路径可能影响已有会话。")
                Text("应用中的登录账号需自行切换。")
                if let verification = visibleVerification {
                    Text("检测时间：\(verification.checkedAt.formatted(date: .omitted, time: .shortened))")
                    if !verification.details.isEmpty { Text(verification.details).textSelection(.enabled) }
                }
                Divider()
                Text(model.statusMessage.isEmpty ? model.engineStatus.message : model.statusMessage)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("network-diagnostic")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 7)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var browserChecksSection: some View {
        BrowserChecksView(model: model)
    }

    @ViewBuilder
    private var activationNoticeCard: some View {
        if let notice = model.activationNotice {
            VStack(alignment: .leading, spacing: 8) {
                Text(notice.message)
                    .font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(notice.message)
                switch notice.nextAction {
                case .openSoftwareSettings:
                    Button("打开软件设置") { showEnvironmentSetup = true }
                        .disabled(model.isBusy)
                case .retry:
                    Button("重新检查") { Task { await model.checkEnvironment() } }
                        .disabled(model.isBusy || model.isCheckingEnvironment)
                case .retryActivation:
                    Button("重试启用所选配置") {
                        if let profile = selectedProfile { activate(profile) }
                    }
                    .disabled(model.isBusy || model.isCheckingEnvironment || selectedProfile == nil)
                    DisclosureGroup("错误详情") {
                        Text(model.statusMessage).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .font(.caption)
                case .none:
                    EmptyView()
                }
            }
            .controlSize(.small)
            .cardStyle()
        }
    }

    private func edit(_ profile: ProxyProfile) {
        do {
            let uri: String
            do { uri = try model.proxyURI(for: profile) }
            catch ProfileStoreError.missingCredentials { uri = "" }
            editor = ProfileEditorRequest(id: profile.id, name: profile.name, accountDescription: profile.accountDescription, uri: uri, isNew: false)
        } catch { localError = error.localizedDescription }
    }

    private func activate(_ profile: ProxyProfile) {
        model.selectedProfileID = profile.id
        Task { await model.activateProfile(profile) }
    }

    private func performAccountAction(_ profile: ProxyProfile) {
        model.selectedProfileID = profile.id
        Task { await model.performAccountNetworkAction(profile) }
    }

    private func copy(_ profile: ProxyProfile) {
        do {
            let uri = try model.proxyURI(for: profile)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(uri, forType: .string)
        } catch { localError = error.localizedDescription }
    }

    private func credentialText(for profile: ProxyProfile) -> String {
        (try? model.proxyURI(for: profile)) ?? "无法读取本机保存的代理链接，请编辑配置重新填写。"
    }
}

private struct ProfileSidebarRow: View {
    let profile: ProxyProfile
    let isSelected: Bool
    let isActive: Bool
    let isOperational: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isSelected ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 23)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if isActive {
                        Text(isOperational ? "生效" : "待检查").font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.13), in: Capsule())
                    }
                    if isSelected {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tint)
                            .help("当前选中；实际生效账号另有标记")
                    }
                }
                if profile.displayDescription != profile.name {
                    Text(profile.displayDescription).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(profile.displayDescription)
                }
                Text(profile.endpoint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).help(profile.endpoint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
    }
}

private struct ProfileEditorRequest: Identifiable {
    let id: UUID
    var name: String
    var accountDescription: String
    var uri: String
    var isNew: Bool

    static var new: ProfileEditorRequest {
        ProfileEditorRequest(id: UUID(), name: "", accountDescription: "", uri: "", isNew: true)
    }
}

private struct ProfileEditor: View {
    @ObservedObject var model: AppModel
    let request: ProfileEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var accountDescription: String
    @State private var uri: String
    @State private var showURI = false
    @State private var saving = false
    @State private var errorMessage: String?

    init(model: AppModel, request: ProfileEditorRequest) {
        self.model = model
        self.request = request
        _name = State(initialValue: request.name)
        _accountDescription = State(initialValue: request.accountDescription)
        _uri = State(initialValue: request.uri)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.rectangle.badge.plus")
                    .font(.system(size: 22)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.isNew ? "添加账号配置" : "编辑账号配置").font(.system(size: 17, weight: .semibold))
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                fieldLabel("配置名称", hint: "例如：Claude 主账号") {
                    TextField("输入易于识别的名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                fieldLabel("账号描述", hint: "记录这个 IP 属于哪个账号") {
                    TextField("例如：邮箱、用途或账号备注", text: $accountDescription, axis: .vertical)
                        .lineLimit(1...2)
                        .textFieldStyle(.roundedBorder)
                }
                fieldLabel("SOCKS5 代理链接", hint: "支持带用户名和密码的链接") {
                    HStack {
                        Group {
                            if showURI {
                                TextField("socks5://用户名:密码@IP:端口", text: $uri)
                            } else {
                                SecureField("socks5://用户名:密码@IP:端口", text: $uri)
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        Button { showURI.toggle() } label: {
                            Image(systemName: showURI ? "eye.slash" : "eye")
                        }
                        .help(showURI ? "隐藏代理凭证" : "显示完整代理链接")
                    }
                }
            }

            Label("完整代理链接保存在本机应用数据文件中，可随时显示或复制。", systemImage: "internaldrive")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !request.isNew && request.uri.isEmpty {
                Label("本机尚未保存此配置的代理链接，请重新填写后保存。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(request.isNew ? "添加配置" : "保存修改") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled(saving)
    }

    private func fieldLabel<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = accountDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if request.isNew {
                    try await model.addProfile(name: cleanName, accountDescription: cleanDescription, uri: cleanURI)
                } else {
                    try await model.updateProfile(id: request.id, name: cleanName, accountDescription: cleanDescription, uri: cleanURI)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }
}

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.075), lineWidth: 1))
    }
}

private extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}
