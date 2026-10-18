import AppKit
import SwiftUI

struct ClaudeToolsView: View {
    @ObservedObject var model: ClaudeToolsModel
    @Environment(\.dismiss) private var dismiss
    @State private var maintenanceMode: ClaudeMaintenanceMode = .reinstall
    @State private var pendingMaintenance: ClaudeMaintenanceMode?
    @State private var confirmNewSession = false
    @State private var showCreateBackup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Claude Code 工具", systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("只读取安装状态和备份列表")
                    .disabled(model.isBusy)
            }
            if let status = model.status {
                HStack(spacing: 10) {
                    Text(status.installationDescription).lineLimit(1).help(status.executablePath ?? status.installationDescription)
                    Spacer()
                    Text("\(status.projectCount) 项目 · \(status.transcriptCount) 对话")
                    Text("\(status.activeProcesses.count) 个进程")
                        .foregroundStyle(status.activeProcesses.isEmpty ? Color.secondary : Color.orange)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            TabView {
                backupContent.tabItem { Label("对话备份", systemImage: "archivebox") }
                maintenanceContent.tabItem { Label("安装维护", systemImage: "wrench") }
            }

            if model.isBusy {
                Text(model.operationTitle).font(.caption).foregroundStyle(.secondary)
            } else if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).help(error).textSelection(.enabled)
            } else if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(message).textSelection(.enabled)
            }
            HStack {
                Text("维护和新会话操作均需主动确认。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
            }
        }
        .padding(16)
        .frame(width: 760, height: 560)
        .interactiveDismissDisabled(model.isBusy)
        .task { await model.refresh() }
        .sheet(isPresented: $showCreateBackup) { ClaudeCreateBackupView(model: model) }
        .alert("确认维护 Claude Code？", isPresented: Binding(get: { pendingMaintenance != nil }, set: { if !$0 { pendingMaintenance = nil } })) {
            Button("取消", role: .cancel) { pendingMaintenance = nil }
            Button("确认备份并执行", role: .destructive) {
                guard let mode = pendingMaintenance else { return }
                pendingMaintenance = nil
                Task { await model.maintain(mode) }
            }
        } message: {
            Text(maintenanceConfirmation)
        }
        .alert("在终端开启新的 Claude Code 会话？", isPresented: $confirmNewSession) {
            Button("取消", role: .cancel) {}
            Button("开启新会话") { launchPreparedSession() }
        } message: {
            Text("将运行已准备的本地启动脚本，按 Claude Code 当前配置把所选上下文发送到当前服务，并产生一个新会话。只迁移可读内容，不沿用旧会话标识。")
        }
        .alert("永久删除此备份？", isPresented: Binding(get: { model.deletionPlan != nil }, set: { if !$0 { model.cancelBackupDeletion() } }), presenting: model.deletionPlan) { plan in
            Button("取消", role: .cancel) { model.cancelBackupDeletion() }
            Button("永久删除", role: .destructive) {
                model.cancelBackupDeletion()
                Task { await model.deleteBackup(plan) }
            }
            .disabled(model.isBusy)
        } message: { plan in
            Text("将永久删除“\(plan.title)”，逻辑文件大小约 \(ClaudeToolsFileSize.format(plan.sizeBytes))。包括备份内的原始文件、\(plan.relatedImportCount) 份关联的新会话上下文，以及 \(plan.relatedRecoveryCount) 份已完成维护的恢复副本。\n\n不会删除 Claude 当前会话或账号。未完成维护引用的备份必须保留。此操作无法撤销。")
        }
    }

    private var backupContent: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("本地备份").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button { showCreateBackup = true } label: { Image(systemName: "plus") }
                        .help("选择全量或时间区间后创建备份")
                        .accessibilityLabel("创建备份")
                        .disabled(model.isBusy)
                }
                if model.backups.isEmpty {
                    Text("暂无备份\n点击 + 创建本地备份。")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(model.backups) { backup in
                                HStack(alignment: .top, spacing: 0) {
                                    Button { Task { await model.openBackup(backup.id) } } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(backup.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                                            Text(backup.dateLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                                            Text(backup.isPartial == true ? "未完成的备份" : "\(backup.conversationCount) 个对话 · \(backup.complete ? "完整" : "有提示")")
                                                .font(.system(size: 10)).foregroundStyle(backup.complete && backup.isPartial != true ? Color.secondary : Color.orange)
                                            HStack(spacing: 5) {
                                                if backup.isPartial != true { Text(backup.scopeLabel).help(backup.rangeDescription ?? "全部可读取的本地对话") }
                                                Text(backup.sizeLabel)
                                            }
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                        }
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain).disabled(model.isBusy)
                                    Button { Task { await model.requestBackupDeletion(backup.id) } } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(backup.canDelete == false ? Color.secondary : Color.red)
                                    }
                                    .buttonStyle(.borderless)
                                    .padding(.top, 8).padding(.trailing, 6)
                                    .help(backup.deleteBlockedReason ?? "检查后永久删除此备份")
                                    .accessibilityLabel("删除备份：\(backup.title)")
                                    .disabled(model.isBusy)
                                }
                                .background(model.selectedBackupID == backup.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                                .contextMenu {
                                    Button("删除备份…", role: .destructive) {
                                        Task { await model.requestBackupDeletion(backup.id) }
                                    }
                                    .disabled(model.isBusy)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: 185)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                if let partial = model.selectedPartialBackup {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("备份未完成，可删除以释放空间", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                        Text(partial.title).font(.subheadline).textSelection(.enabled)
                        Text("\(partial.dateLabel) · 逻辑文件大小\(partial.sizeLabel)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("此目录没有完整的备份清单，无法查看对话或准备新会话。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !partial.warnings.isEmpty {
                            Text(partial.warnings.joined(separator: "\n"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Button("删除此未完成备份…", role: .destructive) {
                            Task { await model.requestBackupDeletion(partial.id) }
                        }
                        .disabled(model.isBusy)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let backup = model.selectedBackup {
                    HStack {
                        Menu {
                            ForEach(backup.conversations) { conversation in
                                Button("\(conversation.title) · \(conversation.messageCount) 条") {
                                    Task { await model.openConversation(conversation.id) }
                                }
                            }
                        } label: {
                            Text(model.conversation?.title ?? "选择对话（\(backup.conversations.count)）")
                                .lineLimit(1)
                        }
                        .disabled(model.isBusy || backup.conversations.isEmpty)
                        Spacer(minLength: 0)
                        if let preview = model.conversation, preview.previewTruncated == true, let path = preview.markdownPath {
                            Button("打开完整 Markdown") { openMarkdown(path) }.font(.caption)
                        }
                    }
                    Text(backup.backup.rangeDescription.map { "时间区间：" + $0 } ?? "范围：全量备份")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        .help(backup.backup.rangeDescription ?? "全部可读取的本地对话")
                    if backup.backup.scope == "range" {
                        Text("只保留所选时间内的消息及对应原始记录，不能用于完整回滚。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if !backup.backup.warnings.isEmpty {
                        Text(backup.backup.warnings.joined(separator: "；"))
                            .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                            .help(backup.backup.warnings.joined(separator: "\n"))
                    }
                    if let conversation = model.conversation {
                        Text(conversation.project).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(conversation.project)
                        if conversation.previewTruncated == true {
                            Text("当前仅显示最多 512 KiB 预览，可打开完整 Markdown。")
                                .font(.system(size: 10)).foregroundStyle(.orange)
                        }
                        ClaudePlainTextPreview(text: conversation.markdown)
                        sessionActions
                    } else {
                        previewPlaceholder("点击“选择对话”查看纯文本内容。")
                    }
                } else {
                    previewPlaceholder("选择左侧备份，再选择一个对话。")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
    }

    private var sessionActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let prepared = model.preparedSession {
                Text(prepared.details + (prepared.omittedMessages > 0 ? " 已省略 \(prepared.omittedMessages) 条消息。" : ""))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).help(prepared.details)
                HStack {
                    Button("预览上下文") { openMarkdown(prepared.contextPath) }
                    Spacer()
                    Button("在终端开启新会话") { confirmNewSession = true }
                        .disabled(model.isBusy)
                }
                .controlSize(.small)
            } else {
                HStack {
                    TextField("新会话工作目录（可选）", text: $model.projectDirectory)
                        .textFieldStyle(.roundedBorder).font(.system(size: 10))
                    Button("准备新会话") { Task { await model.prepareSession() } }
                        .controlSize(.small)
                        .disabled(model.isBusy || model.conversation?.importable != true)
                }
                Text("先生成上下文和启动脚本；随后由你确认是否发送并开启新会话。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var maintenanceContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text("安装维护").font(.system(size: 13, weight: .semibold))
                if let status = model.status {
                    Text(status.installationDescription).font(.subheadline)
                    Text("配置目录：\(status.configDirectory)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if !status.activeProcesses.isEmpty {
                        Text(status.activeProcesses.map { "\($0.name)（PID \($0.pid)）" }.joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Picker("维护方式", selection: $maintenanceMode) {
                    ForEach(ClaudeMaintenanceMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.radioGroup)
                .disabled(model.isBusy)
                Text(maintenanceMode == .reinstall
                     ? "先备份对话与本地恢复资料，再重装程序，保留现有配置。"
                     : "高级操作：先备份，再清理本地配置并重装。原始副本包含旧配置，仅供回滚，绝不导入新会话，也不会自动删除。")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = model.maintenanceBlockReason {
                    Label(reason, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                if model.maintenanceResult == nil, let path = model.status?.recoveryPath, FileManager.default.fileExists(atPath: path) {
                    Button("在 Finder 查看待恢复资料") {
                        do { NSWorkspace.shared.activateFileViewerSelecting([try localURL(path)]) }
                        catch { model.reportLocalError(error) }
                    }
                }
                Text("重装不保证获得新的设备身份，不会删除服务端记录，也不会操作钥匙串或保证退出登录。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(model.status?.installed == false ? "备份并安装" : "备份并重装") { pendingMaintenance = maintenanceMode }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canMaintain)
                }
                if let result = model.maintenanceResult {
                    Divider()
                    Text(result.details).font(.caption).textSelection(.enabled)
                    Text("操作前备份：\(result.backupID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let path = result.recoveryPath {
                        Button("在 Finder 查看原始恢复资料") {
                            do { NSWorkspace.shared.activateFileViewerSelecting([try localURL(path)]) }
                            catch { model.reportLocalError(error) }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var maintenanceConfirmation: String {
        let mode = pendingMaintenance ?? .reinstall
        return "请先结束所有任务，并退出 Claude 或共享配置的客户端进程。程序会先创建备份，再执行“\(mode.title)”。原始恢复副本包含旧配置，仅供回滚，不会导入新会话或自动删除。重装不保证新的设备身份，也不会删除服务端记录。"
    }

    private func previewPlaceholder(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func localURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { throw ClaudeToolsError.operation("本地文件不存在，请重新准备或刷新备份。") }
        return URL(fileURLWithPath: path)
    }

    private func openMarkdown(_ path: String) {
        do {
            let url = try localURL(path)
            guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { throw ClaudeToolsError.operation("只允许打开本地 Markdown 文件。") }
            guard NSWorkspace.shared.open(url) else { throw ClaudeToolsError.operation("无法打开本地 Markdown 文件。") }
        } catch { model.reportLocalError(error) }
    }

    private func launchPreparedSession() {
        guard let prepared = model.preparedSession else { return }
        do {
            let url = try localURL(prepared.commandPath)
            guard url.pathExtension.lowercased() == "command" else { throw ClaudeToolsError.operation("启动文件类型不正确，请重新准备新会话。") }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: configuration) { _, error in
                if let error { Task { @MainActor in model.reportLocalError(error) } }
            }
        } catch { model.reportLocalError(error) }
    }
}

private struct ClaudeCreateBackupView: View {
    @ObservedObject var model: ClaudeToolsModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope: ClaudeBackupScope = .full
    @State private var start = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date())
    @State private var end = Date()
    @State private var endIsNow = true

    private var selection: ClaudeBackupSelection {
        guard scope == .range else { return .full }
        let from = Calendar.current.dateInterval(of: .minute, for: start)?.start ?? start
        let to = Calendar.current.dateInterval(of: .minute, for: end)?.start ?? end
        return .range(start: from, end: endIsNow ? nil : to)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("创建对话备份").font(.system(size: 16, weight: .semibold))
            Picker("备份范围", selection: $scope) {
                ForEach(ClaudeBackupScope.allCases) { item in Text(item.title).tag(item) }
            }
            .pickerStyle(.segmented)
            if scope == .range {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker("开始时间", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    HStack {
                        Text("结束时间")
                        Spacer()
                        Toggle("至今", isOn: $endIsNow).toggleStyle(.checkbox)
                    }
                    if !endIsNow {
                        DatePicker("结束时间", selection: $end, displayedComponents: [.date, .hourAndMinute])
                    }
                    Text("时间按本机时区显示，包含起止时刻；“至今”以开始创建时为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .datePickerStyle(.field)
                Text("只保留所选时间内的消息及对应原始记录；没有时间戳的消息会跳过并提示。时间区间备份不能用于完整回滚。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("备份所有可读取的本地对话。创建备份不会修改 Claude 当前会话或账号。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("即将创建：\(selection.scopeLabel)备份").font(.system(size: 12, weight: .medium))
                Text(selection.summary).font(.caption).foregroundStyle(.secondary)
                if let error = selection.validationError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建备份") {
                    let request = selection
                    guard request.validationError == nil, !model.isBusy else { return }
                    dismiss()
                    Task { await model.createBackup(request) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy || selection.validationError != nil)
            }
        }
        .padding(18)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(model.isBusy)
    }
}

private struct ClaudePlainTextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 250))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }
}
