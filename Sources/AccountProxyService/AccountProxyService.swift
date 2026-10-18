import Foundation
import Darwin

final class AccountProxyService {
    let paths: ServicePaths
    let files: SecureServiceFiles
    let authorization: ServiceAuthorization
    let dns: DNSController
    let detector: ServiceConflictDetector
    let lock = NSRecursiveLock()
    private var core: Process?
    private var ownerUID: uid_t?
    private var generation: String?
    private var desiredActive = false
    private var resumePending = false
    private var secret = UUID().uuidString + UUID().uuidString
    private var lastIssue: String?
    private var lastMonitor = Date.distantPast
    private var http: CoreHTTP { CoreHTTP(socketPath: paths.coreSocket.path, secret: secret) }

    init(paths: ServicePaths) throws {
        guard geteuid() == 0 else { throw HelperFailure(code: "root_service_required", message: "此服务只能由用户授权后的 launchd 系统服务启动。") }
        self.paths = paths
        self.files = SecureServiceFiles(owner: 0)
        self.authorization = ServiceAuthorization(application: paths.bundledCore.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), teamIdentifier: CoreBuildIdentity.teamIdentifier)
        self.dns = DNSController(backupURL: paths.dnsBackup, files: files)
        self.detector = ServiceConflictDetector(ownedCore: paths.core.path)
        try authorization.validateInstallation()
        try files.directory(paths.runtime)
        try files.directory(paths.socketDirectory, mode: 0o755)
        try files.stageCore(from: paths.bundledCore, to: paths.core, expectedHash: CoreBuildIdentity.sha256)
        if let data = try? files.read(paths.state), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ownerUID = (state["ownerUID"] as? NSNumber)?.uint32Value
            generation = state["generation"] as? String
            desiredActive = state["active"] as? Bool == true
        }
        // A previous daemon crash may leave only our root-owned pinned core.
        // Never target another application's process or its configuration.
        let orphans = allProcessIDs().filter { processPath($0) == paths.core.path }
        for pid in orphans { kill(pid, SIGTERM) }
        let orphanDeadline = Date().addingTimeInterval(3)
        while Date() < orphanDeadline, orphans.contains(where: { processPath($0) == paths.core.path }) { Thread.sleep(forTimeInterval: 0.025) }
        for pid in orphans where processPath(pid) == paths.core.path { kill(pid, SIGKILL) }
        let cleanupDeadline = Date().addingTimeInterval(1)
        while Date() < cleanupDeadline, orphans.contains(where: { processPath($0) == paths.core.path }) { Thread.sleep(forTimeInterval: 0.025) }
        try dns.restoreIfOwned()
        resumePending = desiredActive && ownerUID != nil
    }

    func authorizedPeer(_ descriptor: Int32) throws -> uid_t {
        lock.lock(); defer { lock.unlock() }
        return try authorization.peer(descriptor, ownerUID: ownerUID)
    }

    func handle(_ request: HelperRequest, uid: uid_t) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard ownerUID == nil || ownerUID == uid, authorization.consoleUID() == uid else { throw HelperFailure(code: "owner_mismatch", message: "系统服务属于其他用户。") }
        if request.command == "apply" || request.command == "stop" {
            // Recheck the sealed script/resources at the actual mutation boundary.
            // Status/query intentionally avoid rescanning the large app bundle.
            try authorization.validateInstallation()
        }
        switch request.command {
        case "status": return status()
        case "query": return try query(request.endpoint!)
        case "stop":
            try checkGeneration(request.expectedPreviousGeneration)
            desiredActive = false; resumePending = false
            try stopCore()
            try saveState()
            return status()
        case "apply":
            try checkGeneration(request.expectedPreviousGeneration)
            let conflicts = detector.conflicts(ownCoreRunning: core?.isRunning == true)
            guard conflicts.isEmpty else { throw HelperFailure(code: "network_conflict", message: conflicts.joined(separator: "；") + "。请先退出其他代理后再初始化。") }
            let configuration = try HelperConfiguration.validated(request.configuration!, controllerPath: paths.coreSocket.path, secret: secret)
            let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
            try validateCoreConfiguration(data)
            if core?.isRunning == true {
                let oldData = try files.read(paths.configuration)
                do {
                    try files.write(data, to: paths.configuration)
                    _ = try http.request("PUT", "/configs?force=false", body: JSONSerialization.data(withJSONObject: ["payload": String(decoding: data, as: UTF8.self)]))
                } catch {
                    try? files.write(oldData, to: paths.configuration)
                    if (try? http.request("PUT", "/configs?force=false", body: JSONSerialization.data(withJSONObject: ["payload": String(decoding: oldData, as: UTF8.self)]))) == nil {
                        desiredActive = false; try? stopCore(); try? saveState()
                    }
                    throw HelperFailure(code: "reload_failed", message: "切换失败，已尝试恢复前一份配置；未中断其他应用。")
                }
                generation = request.generation; desiredActive = true; lastIssue = nil
                try saveState()
                return status()
            }
            do {
                try detector.requireDNSPortAvailable()
                try files.write(data, to: paths.configuration)
                try startCore()
                try dns.apply()
                ownerUID = uid; generation = request.generation; desiredActive = true; resumePending = false; lastIssue = nil
                try saveState()
                return status()
            } catch {
                desiredActive = false; resumePending = false
                try? stopCore(); try? saveState()
                throw error
            }
        default: throw HelperFailure(code: "invalid_request", message: "不支持的请求。")
        }
    }

    func monitor() {
        lock.lock(); defer { lock.unlock() }
        if let process = core, !process.isRunning {
            core = nil; desiredActive = false; resumePending = false
            do { try dns.restoreIfOwned(); try saveState(); lastIssue = "网络核心已退出，系统 DNS 已恢复。" }
            catch { lastIssue = "网络核心已退出；系统 DNS 恢复尚未完成，请重新打开应用检查。" }
        }
        if core?.isRunning != true, FileManager.default.fileExists(atPath: paths.dnsBackup.path) {
            do { try dns.restoreIfOwned() }
            catch { lastIssue = "系统 DNS 恢复尚未完成，正在安全重试。"; return }
        }
        if ServiceOwnerSessionDecision.decide(ownerUID: ownerUID, consoleUID: authorization.consoleUID(), running: core?.isRunning == true, activeIntent: desiredActive) == .pause {
            resumePending = desiredActive
            do { try stopCore(forceStopIfDNSRestoreFails: true); try saveState(); lastIssue = "已暂停账号网络，等待原用户返回。" }
            catch { lastIssue = "用户已切换；本应用网络已暂停，DNS 恢复需重试。" }
            return
        }
        if core?.isRunning == true && !desiredActive {
            do { try stopCore(); try saveState() }
            catch { lastIssue = "正在重试恢复本应用 DNS，暂保留本地解析器以免断网。" }
            return
        }
        guard Date().timeIntervalSince(lastMonitor) >= 5 else { return }
        lastMonitor = Date()
        if core?.isRunning == true {
            let conflicts = detector.conflicts(ownCoreRunning: true)
            if !detector.ownsTunnel() {
                desiredActive = false; resumePending = false
                try? stopCore(); try? saveState(); lastIssue = "专用 TUN 已退出，已停用本应用并尝试恢复 DNS。"
            } else if !conflicts.isEmpty {
                desiredActive = false; resumePending = false
                try? stopCore(); try? saveState()
                lastIssue = "检测到其他代理，已停用本应用网络并尝试恢复 DNS。"
            } else {
                do { try dns.apply() } catch { desiredActive = false; try? stopCore(); try? saveState(); lastIssue = "无法安全维护 DNS，已停用本应用网络。" }
            }
        } else if resumePending, let uid = ownerUID, authorization.consoleUID() == uid {
            do {
                let conflicts = detector.conflicts(ownCoreRunning: false)
                guard conflicts.isEmpty else { lastIssue = "自动恢复等待其他代理退出。"; return }
                try detector.requireDNSPortAvailable()
                let original = try JSONSerialization.jsonObject(with: files.read(paths.configuration)) as? [String: Any] ?? [:]
                var allowed = original.filter { HelperConfiguration.allowedTopKeys.contains($0.key) }
                if var tun = allowed["tun"] as? [String: Any] { tun.removeValue(forKey: "device"); allowed["tun"] = tun }
                let configuration = try HelperConfiguration.validated(allowed, controllerPath: paths.coreSocket.path, secret: secret)
                let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
                try validateCoreConfiguration(data)
                try files.write(data, to: paths.configuration)
                try startCore(); try dns.apply()
                resumePending = false; lastIssue = nil; try saveState()
            } catch {
                try? stopCore(); lastIssue = "自动恢复尚未完成，请在应用中继续初始化。"
            }
        }
    }

    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        // Preserve only the user's prior successful activation intent for boot.
        try? stopCore(forceStopIfDNSRestoreFails: true); try? saveState()
    }

    private func startCore() throws {
        unlink(paths.coreSocket.path)
        let process = Process()
        process.executableURL = paths.core
        process.arguments = ["-d", paths.runtime.path, "-f", paths.configuration.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": paths.runtime.path, "TMPDIR": paths.runtime.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); core = process
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, process.isRunning {
            if (try? http.request("GET", "/version")) != nil && detector.ownsTunnel() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw HelperFailure(code: "core_start_failed", message: "网络核心未能启动；系统 DNS 将保持或恢复原设置。")
    }
    private func validateCoreConfiguration(_ data: Data) throws {
        let pending = paths.runtime.appendingPathComponent("pending.json")
        try files.write(data, to: pending)
        defer { unlink(pending.path) }
        let process = Process()
        process.executableURL = paths.core
        process.arguments = ["-t", "-d", paths.runtime.path, "-f", pending.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": paths.runtime.path, "TMPDIR": paths.runtime.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning { process.terminate(); throw HelperFailure(code: "configuration_timeout", message: "网络配置检查超时。") }
        guard process.terminationStatus == 0 else { throw HelperFailure(code: "configuration_invalid", message: "网络核心拒绝了这份配置。") }
    }
    private func stopCore(forceStopIfDNSRestoreFails: Bool = false) throws {
        // Keep the local resolver alive until its DNS override is restored. If
        // configd is temporarily busy, the watchdog retries without stranding
        // the Mac on 127.0.0.1 after killing its only resolver.
        var restoreFailure: Error?
        do { try dns.restoreIfOwned() }
        catch {
            if !forceStopIfDNSRestoreFails { throw error }
            restoreFailure = error
        }
        if let process = core, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        core = nil
        unlink(paths.coreSocket.path)
        if let restoreFailure { throw restoreFailure }
    }
    private func checkGeneration(_ expected: String?) throws {
        guard expected == nil || expected == (generation ?? "") else { throw HelperFailure(code: "generation_conflict", message: "网络配置已变化，请刷新后重试。") }
    }
    private func status() -> [String: Any] {
        let running = core?.isRunning == true
        var result: [String: Any] = ["running": running, "tunEnabled": running && detector.ownsTunnel(), "coreVersion": CoreBuildIdentity.version,
                                    "conflicts": detector.conflicts(ownCoreRunning: running),
                                    "dnsRestorationPending": DNSRestorationStatus.isPending(hasBackup: FileManager.default.fileExists(atPath: paths.dnsBackup.path), running: running, activeIntent: desiredActive, ownerUID: ownerUID, consoleUID: authorization.consoleUID())]
        if let process = core, running { result["pid"] = process.processIdentifier }
        if let uid = ownerUID { result["ownerUID"] = uid }
        if let generation { result["generation"] = generation }
        if let issue = lastIssue { result["message"] = issue }
        return result
    }
    private func query(_ endpoint: String) throws -> [String: Any] {
        guard core?.isRunning == true else { throw HelperFailure(code: "core_not_running", message: "本应用网络尚未启用。") }
        switch endpoint {
        case "configs":
            let value = try http.request("GET", "/configs")
            return value.filter { ["mode", "ipv6", "tun", "mixed-port", "bind-address", "allow-lan"].contains($0.key) }
        case "proxies":
            let value = try http.request("GET", "/proxies/Account%20Proxy%20Exit")
            return value.filter { ["name", "type", "now", "all", "udp"].contains($0.key) }
        case "rules": return try http.request("GET", "/rules")
        case "connections": return try http.request("GET", "/connections")
        default: throw HelperFailure(code: "invalid_endpoint", message: "查询不受支持。")
        }
    }
    private func saveState() throws {
        var state: [String: Any] = ["version": 1, "active": desiredActive]
        if let uid = ownerUID { state["ownerUID"] = uid }
        if let generation { state["generation"] = generation }
        try files.write(JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), to: paths.state)
    }
}
