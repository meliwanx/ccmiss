import Foundation
import Combine

struct ClaudeToolsStatus: Decodable, Sendable {
    let installed: Bool
    let installationKind: String
    let installationDescription: String
    let executablePath: String?
    let configDirectory: String
    let projectCount: Int
    let transcriptCount: Int
    let activeProcesses: [ClaudeToolsProcess]
    let maintenanceSupported: Bool
    let maintenanceReason: String
    let planHash: String
    let recoveryPath: String?
}

struct ClaudeToolsProcess: Decodable, Identifiable, Sendable {
    let pid: Int
    let name: String
    var id: Int { pid }
}

struct ClaudeBackupSummary: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let createdAt: String
    let conversationCount: Int
    let messageCount: Int
    let complete: Bool
    let warnings: [String]
    let sizeBytes: Int64?
    let canDelete: Bool?
    let deleteBlockedReason: String?
    let scope: String?
    let rangeStart: String?
    let rangeEnd: String?
    let rangeEndIsNow: Bool?
    let isPartial: Bool?

    var sizeLabel: String {
        sizeBytes.map { "约 " + ClaudeToolsFileSize.format($0) } ?? "大小待计算"
    }

    var dateLabel: String {
        ClaudeToolsDates.parse(createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? createdAt
    }

    var scopeLabel: String { scope == "range" ? "时间区间" : "全量" }

    var rangeDescription: String? {
        guard scope == "range", let rangeStart else { return nil }
        let start = ClaudeToolsDates.display(rangeStart)
        let end = rangeEnd.map(ClaudeToolsDates.display) ?? "至今"
        return start + " → " + (rangeEndIsNow == true ? "至今（\(end)）" : end)
    }
}

enum ClaudeBackupScope: String, CaseIterable, Identifiable {
    case full, range
    var id: String { rawValue }
    var title: String { self == .full ? "全量备份" : "时间区间" }
}

enum ClaudeBackupSelection: Sendable {
    case full
    case range(start: Date, end: Date?)

    var scopeLabel: String {
        switch self { case .full: return "全量"; case .range: return "时间区间" }
    }

    var summary: String {
        switch self {
        case .full: return "全部可读取的本地对话"
        case .range(let start, let end):
            return start.formatted(date: .abbreviated, time: .shortened) + " → " + (end?.formatted(date: .abbreviated, time: .shortened) ?? "至今（创建开始时）")
        }
    }

    var validationError: String? {
        guard case .range(let start, let end) = self else { return nil }
        guard start <= (end ?? Date()) else { return "开始时间不能晚于结束时间。" }
        return nil
    }
}

enum ClaudeToolsDates {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func display(_ value: String) -> String {
        parse(value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    static func encode(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }
}

struct ClaudeConversationSummary: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let project: String
    let messageCount: Int
    let createdAt: String?
}

struct ClaudeBackupDetail: Decodable, Sendable {
    let backup: ClaudeBackupSummary
    let conversations: [ClaudeConversationSummary]
}

struct ClaudeConversationPreview: Decodable, Sendable {
    let title: String
    let project: String
    let markdown: String
    let importable: Bool
    let markdownPath: String?
    let previewTruncated: Bool?
}

struct ClaudePreparedSession: Decodable, Sendable {
    let contextPath: String
    let commandPath: String
    let omittedMessages: Int
    let details: String
}

struct ClaudeMaintenanceResult: Decodable, Sendable {
    let success: Bool
    let backupID: String
    let details: String
    let recoveryPath: String?
}

struct ClaudeBackupDeletionPlan: Decodable, Sendable {
    let backupID: String
    let title: String
    let sizeBytes: Int64
    let relatedImportCount: Int
    let relatedRecoveryCount: Int
    let canDelete: Bool
    let reason: String
    let planHash: String
}

struct ClaudeBackupDeletionResult: Decodable, Sendable {
    let deleted: Bool
    let backupID: String
    let reclaimedBytes: Int64
    let details: String
    let recoveryPath: String?
}

enum ClaudeToolsFileSize {
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum ClaudeMaintenanceMode: String, CaseIterable, Identifiable, Sendable {
    case reinstall
    case cleanReinstall
    var id: String { rawValue }
    var title: String { self == .reinstall ? "保留配置重装" : "清理本地配置后重装" }
}

@MainActor
final class ClaudeToolsModel: ObservableObject {
    static let shared = ClaudeToolsModel()

    @Published private(set) var status: ClaudeToolsStatus?
    @Published private(set) var backups: [ClaudeBackupSummary] = []
    @Published private(set) var selectedBackup: ClaudeBackupDetail?
    @Published private(set) var selectedPartialBackup: ClaudeBackupSummary?
    @Published private(set) var selectedConversationID: String?
    @Published private(set) var conversation: ClaudeConversationPreview?
    @Published private(set) var preparedSession: ClaudePreparedSession?
    @Published private(set) var maintenanceResult: ClaudeMaintenanceResult?
    @Published private(set) var deletionPlan: ClaudeBackupDeletionPlan?
    @Published private(set) var isBusy = false
    @Published private(set) var operationTitle = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var message: String?
    @Published private(set) var hasFreshStatus = false
    @Published var projectDirectory = ""

    private let service = ClaudeToolsService()

    var selectedBackupID: String? { selectedPartialBackup?.id ?? selectedBackup?.backup.id }

    var canMaintain: Bool {
        guard let status else { return false }
        return !isBusy && hasFreshStatus && status.maintenanceSupported && status.activeProcesses.isEmpty && !status.planHash.isEmpty
    }

    var maintenanceBlockReason: String? {
        guard let status, hasFreshStatus else { return "请先刷新并确认 Claude Code 的当前状态。" }
        if !status.activeProcesses.isEmpty { return "检测到 \(status.activeProcesses.count) 个 Claude 或共享配置的客户端进程。请在任务结束后自行退出这些进程，再刷新状态。" }
        if !status.maintenanceSupported { return status.maintenanceReason.isEmpty ? "当前安装方式不支持自动维护。" : status.maintenanceReason }
        return nil
    }

    func refresh() async {
        await perform("正在读取状态与备份列表…") {
            self.hasFreshStatus = false
            var errors: [String] = []
            do {
                self.status = try await self.service.status()
                self.hasFreshStatus = true
            } catch {
                errors.append("安装状态读取失败：" + error.localizedDescription)
            }
            do {
                self.backups = try await self.service.listBackups()
                self.synchronizeBackupSelection()
            } catch {
                errors.append("备份列表读取失败：" + error.localizedDescription)
            }
            if !errors.isEmpty { throw ClaudeToolsError.operation(errors.joined(separator: "\n")) }
        }
    }

    func createBackup(_ selection: ClaudeBackupSelection) async {
        if let error = selection.validationError { errorMessage = error; return }
        await perform("正在创建本地对话备份…") {
            let backup: ClaudeBackupSummary
            do { backup = try await self.service.backup(selection) }
            catch {
                // A failed backup may leave an incomplete directory that the user can explicitly delete.
                if let backups = try? await self.service.listBackups() { self.backups = backups; self.synchronizeBackupSelection() }
                throw error
            }
            self.backups.removeAll { $0.id == backup.id }
            self.backups.insert(backup, at: 0)
            self.message = "已保存\(selection.scopeLabel)备份：\(backup.conversationCount) 个对话、\(backup.messageCount) 条消息。范围：\(backup.rangeDescription ?? selection.summary)。" + (backup.complete ? "" : "备份有提示，请查看详情。")
            do { self.backups = try await self.service.listBackups(); self.synchronizeBackupSelection() }
            catch { self.errorMessage = "备份已创建，但刷新列表失败：" + error.localizedDescription }
        }
    }

    func requestBackupDeletion(_ backupID: String) async {
        await perform("正在检查备份大小与删除条件…") {
            self.deletionPlan = nil
            let plan = try await self.service.backupDeletionPlan(backupID)
            guard plan.canDelete else {
                throw ClaudeToolsError.operation(plan.reason.isEmpty ? "此备份当前不能删除，未完成维护引用的备份必须保留。" : plan.reason)
            }
            self.deletionPlan = plan
        }
    }

    func cancelBackupDeletion() { deletionPlan = nil }

    func deleteBackup(_ plan: ClaudeBackupDeletionPlan) async {
        guard plan.canDelete, !plan.planHash.isEmpty else { return }
        await perform("正在永久删除所选备份…") {
            let result = try await self.service.deleteBackup(plan.backupID, expectedPlanHash: plan.planHash)
            guard result.deleted else {
                if let backups = try? await self.service.listBackups() {
                    self.backups = backups
                    self.synchronizeBackupSelection()
                }
                let remaining = result.recoveryPath.map { "\n剩余文件：" + $0 } ?? ""
                throw ClaudeToolsError.operation(result.details + remaining)
            }
            self.backups.removeAll { $0.id == result.backupID }
            if self.selectedBackupID == result.backupID { self.clearBackupSelection() }
            if self.maintenanceResult?.backupID == result.backupID { self.maintenanceResult = nil }
            self.deletionPlan = nil
            self.message = result.details + " 已删除文件的逻辑大小约 " + ClaudeToolsFileSize.format(result.reclaimedBytes) + "。"
            do { self.backups = try await self.service.listBackups() }
            catch { self.errorMessage = "备份已删除，但刷新列表失败：" + error.localizedDescription }
        }
    }

    func openBackup(_ id: String) async {
        guard !isBusy else { return }
        if let backup = backups.first(where: { $0.id == id }), backup.isPartial == true {
            clearBackupSelection()
            selectedPartialBackup = backup
            errorMessage = nil
            message = nil
            return
        }
        await perform("正在读取备份目录…") {
            self.selectedBackup = try await self.service.readBackup(id)
            self.selectedPartialBackup = nil
            self.selectedConversationID = nil
            self.conversation = nil
            self.preparedSession = nil
        }
    }

    func openConversation(_ id: String) async {
        guard let backup = selectedBackup else { return }
        await perform("正在读取对话预览…") {
            self.conversation = try await self.service.readConversation(backupID: backup.backup.id, conversationID: id)
            self.selectedConversationID = id
            self.preparedSession = nil
        }
    }

    func prepareSession() async {
        guard let backup = selectedBackup, let id = selectedConversationID, conversation?.importable == true else { return }
        await perform("正在准备新会话文件…") {
            let directory = self.projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            self.preparedSession = try await self.service.prepareImport(backupID: backup.backup.id, conversationID: id, projectDirectory: directory.isEmpty ? nil : directory)
            self.message = self.preparedSession?.details
        }
    }

    func maintain(_ mode: ClaudeMaintenanceMode) async {
        guard canMaintain, let current = status else {
            errorMessage = maintenanceBlockReason
            return
        }
        await perform("正在备份并维护 Claude Code，请保持应用打开…") {
            let result = try await self.service.maintain(mode: mode, expectedPlanHash: current.planHash)
            self.maintenanceResult = result
            self.message = result.details
            self.hasFreshStatus = false
            if let updated = try? await self.service.status() {
                self.status = updated
                self.hasFreshStatus = true
            }
            if let backups = try? await self.service.listBackups() { self.backups = backups }
            guard result.success else { throw ClaudeToolsError.operation(result.details) }
        }
    }

    func reportLocalError(_ error: Error) { errorMessage = error.localizedDescription }

    private func clearBackupSelection() {
        selectedBackup = nil
        selectedPartialBackup = nil
        selectedConversationID = nil
        conversation = nil
        preparedSession = nil
    }

    private func synchronizeBackupSelection() {
        guard let id = selectedBackupID else { return }
        guard let backup = backups.first(where: { $0.id == id }) else { clearBackupSelection(); return }
        if selectedPartialBackup != nil {
            if backup.isPartial == true { selectedPartialBackup = backup }
            else { clearBackupSelection() }
        } else if backup.isPartial == true {
            clearBackupSelection()
            selectedPartialBackup = backup
        }
    }

    private func perform(_ title: String, action: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        operationTitle = title
        errorMessage = nil
        message = nil
        defer { isBusy = false; operationTitle = "" }
        do { try await action() }
        catch { errorMessage = error.localizedDescription }
    }
}
