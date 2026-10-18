import Foundation
import Darwin

enum ClaudeToolsError: LocalizedError {
    case unavailable, invalidResponse, responseTooLarge
    case operation(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "未找到内置 Claude Code 工具或 Node.js，请重新安装完整的 ccmiss。"
        case .invalidResponse: return "Claude Code 工具返回了无效响应，未展示其原始输出。"
        case .responseTooLarge: return "工具响应超过 8 MB，请使用本地备份文件查看完整内容。"
        case .operation(let text): return text
        }
    }
}

actor ClaudeToolsService {
    private struct BackupResult: Decodable { let backup: ClaudeBackupSummary }
    private struct BackupList: Decodable { let backups: [ClaudeBackupSummary] }

    func status() async throws -> ClaudeToolsStatus {
        try await request("status", as: ClaudeToolsStatus.self)
    }
    func listBackups() async throws -> [ClaudeBackupSummary] {
        try await request("listBackups", as: BackupList.self).backups
    }
    func backup(_ selection: ClaudeBackupSelection) async throws -> ClaudeBackupSummary {
        var payload: [String: String]
        switch selection {
        case .full: payload = ["scope": "full"]
        case .range(let start, let end):
            payload = ["scope": "range", "start": ClaudeToolsDates.encode(start)]
            if let end { payload["end"] = ClaudeToolsDates.encode(end) }
        }
        return try await request("backup", payload: payload, as: BackupResult.self).backup
    }
    func backupDeletionPlan(_ backupID: String) async throws -> ClaudeBackupDeletionPlan {
        try await request("backupDeletionPlan", payload: ["backupID": backupID], as: ClaudeBackupDeletionPlan.self)
    }
    func deleteBackup(_ backupID: String, expectedPlanHash: String) async throws -> ClaudeBackupDeletionResult {
        try await request("deleteBackup", payload: ["backupID": backupID, "confirmation": "DELETE_BACKUP", "expectedPlanHash": expectedPlanHash], as: ClaudeBackupDeletionResult.self)
    }
    func readBackup(_ id: String) async throws -> ClaudeBackupDetail {
        try await request("readBackup", payload: ["backupID": id], as: ClaudeBackupDetail.self)
    }
    func readConversation(backupID: String, conversationID: String) async throws -> ClaudeConversationPreview {
        try await request("readConversation", payload: ["backupID": backupID, "conversationID": conversationID], as: ClaudeConversationPreview.self)
    }
    func prepareImport(backupID: String, conversationID: String, projectDirectory: String?) async throws -> ClaudePreparedSession {
        var payload = ["backupID": backupID, "conversationID": conversationID]
        if let projectDirectory { payload["projectDirectory"] = projectDirectory }
        return try await request("prepareImport", payload: payload, as: ClaudePreparedSession.self)
    }
    func maintain(mode: ClaudeMaintenanceMode, expectedPlanHash: String) async throws -> ClaudeMaintenanceResult {
        try await request("maintain", payload: ["mode": mode.rawValue, "confirmation": "REINSTALL", "expectedPlanHash": expectedPlanHash], as: ClaudeMaintenanceResult.self)
    }

    private func request<Result: Decodable>(_ operation: String, payload: [String: String] = [:], as type: Result.Type) async throws -> Result {
        guard let resources = Bundle.main.resourceURL else { throw ClaudeToolsError.unavailable }
        let executable = resources.appendingPathComponent("node")
        let script = resources.appendingPathComponent("claude-tools.js")
        guard FileManager.default.isExecutableFile(atPath: executable.path), FileManager.default.fileExists(atPath: script.path) else { throw ClaudeToolsError.unavailable }
        var envelope = payload
        envelope["operation"] = operation
        let input = try JSONSerialization.data(withJSONObject: envelope)
        let output = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = [script.path]
            process.currentDirectoryURL = resources
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "NODE_OPTIONS")
            environment.removeValue(forKey: "NODE_PATH")
            process.environment = environment
            let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            // Never log tool output, conversation text, credentials or request bodies.
            errorPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            defer { errorPipe.fileHandleForReading.readabilityHandler = nil }
            try process.run()
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
            var data = Data()
            while let chunk = try outputPipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard data.count + chunk.count <= 8 * 1024 * 1024 else {
                    process.terminate()
                    let deadline = Date().addingTimeInterval(0.5)
                    while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    throw ClaudeToolsError.responseTooLarge
                }
                data.append(chunk)
            }
            process.waitUntilExit()
            return data
        }.value
        guard let reply = try? JSONSerialization.jsonObject(with: output) as? [String: Any], let ok = reply["ok"] as? Bool else { throw ClaudeToolsError.invalidResponse }
        guard ok else {
            var message = reply["error"] as? String ?? "Claude Code 工具操作未完成。"
            if let recovery = reply["recoveryPath"] as? String { message += "\n恢复资料：" + recovery }
            throw ClaudeToolsError.operation(message)
        }
        guard let result = reply["result"], JSONSerialization.isValidJSONObject(result) else { throw ClaudeToolsError.invalidResponse }
        do { return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: result)) }
        catch { throw ClaudeToolsError.invalidResponse }
    }
}
