import Foundation

/// The engine accepts credentials only over its anonymous stdin pipe.
/// Its JSON output is returned in memory; request and response bodies are never logged.
actor StandaloneEngine {
    enum EngineError: LocalizedError {
        case unavailable(String)
        case invalidResponse
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .failed(let message): return message
            case .invalidResponse: return "网络配置后端返回了无效数据。"
            }
        }
    }

    func request(_ operation: String, payload: [String: Any] = [:]) async throws -> [String: Any] {
        let resourceDirectory = Bundle.main.resourceURL
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let candidates = [resourceDirectory, sourceDirectory].compactMap { $0 }
        guard let resources = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("network-engine.js").path)
        }) else { throw EngineError.unavailable("未找到独立网络后端，请重新安装完整软件。") }

        let nodeCandidates = [resources.appendingPathComponent("node").path,
                              "/opt/homebrew/bin/node", "/usr/local/bin/node",
                              FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/node").path]
        guard let executable = nodeCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw EngineError.unavailable("缺少内置 Node.js 运行时，请重新安装完整的应用。")
        }

        var envelope = payload
        envelope["operation"] = operation
        let input = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [resources.appendingPathComponent("network-engine.js").path]
            process.currentDirectoryURL = resources
            let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            // Drain without logging: third-party runtime errors may contain private paths.
            process.standardError = stderrPipe
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
            defer { stderrPipe.fileHandleForReading.readabilityHandler = nil }

            try process.run()
            try stdinPipe.fileHandleForWriting.write(contentsOf: input)
            try stdinPipe.fileHandleForWriting.close()
            let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard output.count <= 2 * 1024 * 1024,
                  let response = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                throw EngineError.invalidResponse
            }
            guard response["ok"] as? Bool == true,
                  let result = response["result"] as? [String: Any] else {
                throw EngineError.failed(response["error"] as? String ?? "网络配置操作失败。")
            }
            return result
        }.value
    }
}
