import AppKit
import Foundation
import Darwin

struct BrowserEnvironmentStatus: Codable, Equatable {
    enum State: String, Codable { case ready, needsAction, unsupported, error }
    let state: State
    let browserName: String
    let summary: String
    let details: String
    let restartRequired: Bool
    let requiresFileAccess: Bool
    let isBrowserRunning: Bool
    let canInitialize: Bool
    let protectedProfileCount: Int
    let totalProfileCount: Int

    var isReady: Bool { state == .ready }
}

/// Only changes user-owned profile preferences while the browser is closed.
/// Does not install enterprise policies, extensions, or terminate browser tasks.
/// Chromium documents that ordinary macOS defaults are only recommended policies:
/// https://www.chromium.org/administrators/mac-quick-start/
/// The actual profile preference mapping is maintained in Chromium's
/// components/policy/test/data/pref_mapping/WebRtcIPHandling.json.
@MainActor
enum BrowserEnvironmentService {
    static func inspect() -> BrowserEnvironmentStatus { perform(initialize: false) }
    static func initialize() -> BrowserEnvironmentStatus { perform(initialize: true) }

    private static func perform(initialize: Bool) -> BrowserEnvironmentStatus {
        var browserName = "浏览器"
        var browserRunning = false
        do {
            let browser = try BrowserLauncher.defaultBrowser()
            browserName = browser.name
            browserRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).isEmpty
            guard let relativePath = dataDirectory(for: browser.bundleIdentifier) else {
                return BrowserEnvironmentStatus(state: .unsupported, browserName: browser.name,
                    summary: "\(browser.name) 的 WebRTC 需手动检查",
                    details: "本应用暂不支持自动配置此浏览器。可使用 Chrome、Edge 或 Brave 作为默认浏览器后继续；也可自行设置此浏览器并用“WebRTC”检测验证。网络与 DNS 初始化可独立完成。",
                    restartRequired: false, requiresFileAccess: false, isBrowserRunning: false, canInitialize: false, protectedProfileCount: 0, totalProfileCount: 0)
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let store = ChromiumWebRTCPreferences(
                rootDirectory: home.appendingPathComponent("Library/Application Support").appendingPathComponent(relativePath),
                backupDirectory: home.appendingPathComponent("Library/Application Support/AccountProxySwitcher/backups/browser"))
            let running = { !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).isEmpty }
            let current = try store.snapshot()
            if current.conflictingURLRules {
                return status(browser.name, current, running: running(), reason: "检测到按网站覆盖 WebRTC 的配置；为保留现有设置，请先在浏览器内检查这些规则。", state: .needsAction)
            }
            if current.profiles.isEmpty {
                return status(browser.name, current, running: running(), reason: "请先打开一次此浏览器创建用户配置，然后回到这里继续初始化。", state: .needsAction)
            }
            if current.protectedCount == current.profiles.count {
                return status(browser.name, current, running: running(), reason: "已读到全部现有用户配置中的 WebRTC 保护设置。可用检测按钮核对实际结果；扩展或组织策略仍可能覆盖偏好设置。", state: .ready)
            }
            if !initialize || running() {
                return status(browser.name, current, running: running(), reason: "请自行完全退出 \(browser.name) 后点击继续初始化；应用会备份并配置所有现有用户配置，不会结束浏览器或正在执行的任务。", state: .needsAction)
            }
            do { try store.initialize(browserIsRunning: running) }
            catch {
                if BrowserEnvironmentErrorMapper.isFileAccessError(error) {
                    return BrowserEnvironmentErrorMapper.status(for: error, browserName: browser.name, isBrowserRunning: running())
                }
                if let partial = try? store.snapshot() {
                    return status(browser.name, partial, running: running(), reason: error.localizedDescription + " 原配置备份已保留；已改动的配置会在安全时自动回退。", state: .error)
                }
                throw error
            }
            let result = try store.snapshot()
            return status(browser.name, result, running: false, reason: "WebRTC 保护已保存；重新打开浏览器后生效。原偏好设置已备份。新建浏览器用户配置后，请再次运行初始化检查。", state: result.protectedCount == result.profiles.count ? .ready : .needsAction)
        } catch {
            return BrowserEnvironmentErrorMapper.status(for: error, browserName: browserName, isBrowserRunning: browserRunning)
        }
    }

    private static func status(_ name: String, _ snapshot: ChromiumWebRTCPreferences.Snapshot, running: Bool, reason: String, state: BrowserEnvironmentStatus.State) -> BrowserEnvironmentStatus {
        BrowserEnvironmentStatus(state: state, browserName: name,
            summary: state == .ready ? "\(name) WebRTC 配置已就绪" : "\(name) WebRTC：\(snapshot.protectedCount)/\(snapshot.profiles.count) 个配置已保护",
            details: reason, restartRequired: running && state != .ready, requiresFileAccess: false,
            isBrowserRunning: running, canInitialize: !running && (state == .needsAction || state == .error) && !snapshot.profiles.isEmpty && !snapshot.conflictingURLRules,
            protectedProfileCount: snapshot.protectedCount, totalProfileCount: snapshot.profiles.count)
    }

    private static func dataDirectory(for identifier: String) -> String? {
        switch identifier.lowercased() {
        case "com.google.chrome": return "Google/Chrome"
        case "com.google.chrome.beta": return "Google/Chrome Beta"
        case "com.google.chrome.dev": return "Google/Chrome Dev"
        case "com.google.chrome.canary": return "Google/Chrome Canary"
        case "org.chromium.chromium": return "Chromium"
        case "com.brave.browser": return "BraveSoftware/Brave-Browser"
        case "com.brave.browser.beta": return "BraveSoftware/Brave-Browser-Beta"
        case "com.brave.browser.nightly": return "BraveSoftware/Brave-Browser-Nightly"
        case "com.microsoft.edgemac": return "Microsoft Edge"
        case "com.microsoft.edgemac.beta": return "Microsoft Edge Beta"
        case "com.microsoft.edgemac.dev": return "Microsoft Edge Dev"
        case "com.microsoft.edgemac.canary": return "Microsoft Edge Canary"
        default: return nil
        }
    }
}

/// Pure error mapping, also exercised offline without requesting macOS permissions.
enum BrowserEnvironmentErrorMapper {
    static func isFileAccessError(_ error: Error) -> Bool { isFileAccessError(error as NSError, depth: 0) }

    private static func isFileAccessError(_ error: NSError, depth: Int) -> Bool {
        guard depth < 8 else { return false }
        if error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           isFileAccessError(underlying, depth: depth + 1) { return true }
        if let underlying = error.userInfo["NSMultipleUnderlyingErrors"] as? [NSError],
           underlying.contains(where: { isFileAccessError($0, depth: depth + 1) }) { return true }
        return false
    }

    static func status(for error: Error, browserName: String, isBrowserRunning: Bool) -> BrowserEnvironmentStatus {
        if isFileAccessError(error) {
            return BrowserEnvironmentStatus(state: .needsAction, browserName: browserName,
                summary: "需要浏览器配置文件访问权限",
                details: "macOS 正在保护 \(browserName) 的用户资料，应用目前无法读取或修改 WebRTC 配置。请在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中允许“ccmiss”，然后完全退出并重新打开本应用，再检查初始化。这是系统文件访问授权，不是钥匙串密码。当前浏览器保护覆盖范围尚无法确认。",
                restartRequired: false, requiresFileAccess: true, isBrowserRunning: isBrowserRunning,
                canInitialize: false, protectedProfileCount: 0, totalProfileCount: 0)
        }
        return BrowserEnvironmentStatus(state: .error, browserName: browserName,
            summary: "浏览器保护尚未完成", details: error.localizedDescription,
            restartRequired: false, requiresFileAccess: false, isBrowserRunning: isBrowserRunning,
            canInitialize: false, protectedProfileCount: 0, totalProfileCount: 0)
    }
}

/// Independent, injectable file implementation so tests never touch real profiles.
struct ChromiumWebRTCPreferences {
    static let protectedValue = "disable_non_proxied_udp"
    let rootDirectory: URL
    let backupDirectory: URL

    struct Profile {
        let url: URL
        let data: Data
        let preferences: [String: Any]
        var isProtected: Bool {
            (preferences["webrtc"] as? [String: Any])?["ip_handling_policy"] as? String == ChromiumWebRTCPreferences.protectedValue
        }
        var hasURLRules: Bool {
            guard let value = (preferences["webrtc"] as? [String: Any])?["ip_handling_url"] else { return false }
            return (value as? [Any])?.isEmpty != true
        }
    }
    struct Snapshot {
        let profiles: [Profile]
        var protectedCount: Int { profiles.filter { $0.isProtected }.count }
        var conflictingURLRules: Bool { profiles.contains { $0.hasURLRules } }
    }
    enum PreferenceError: LocalizedError {
        case unsafePath, malformedProfile(String), browserRunning, changedProfile, urlOverrides
        var errorDescription: String? {
            switch self {
            case .unsafePath: return "浏览器配置路径不是普通文件夹或文件，已保留原文件。"
            case .malformedProfile(let name): return "无法读取浏览器用户配置 \(name)，已保留原文件。"
            case .browserRunning: return "浏览器仍在运行，请完全退出浏览器后继续初始化。"
            case .changedProfile: return "浏览器偏好设置在初始化期间变化，已停止写入；请关闭浏览器后重试。"
            case .urlOverrides: return "存在按网站覆盖的 WebRTC 规则，请先在浏览器内检查这些规则。"
            }
        }
    }

    func snapshot() throws -> Snapshot {
        let fm = FileManager.default
        try rejectSymbolicLinkAncestors(rootDirectory)
        guard try existingAttributes(rootDirectory) != nil else { return Snapshot(profiles: []) }
        try requireType(rootDirectory, expected: .typeDirectory)
        let directories = try fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var profiles: [Profile] = []
        for directory in directories {
            try requireType(directory, expected: .typeDirectory)
            let preferences = directory.appendingPathComponent("Preferences")
            guard try existingAttributes(preferences) != nil else { continue }
            try requireType(preferences, expected: .typeRegular)
            let attributes = try fm.attributesOfItem(atPath: preferences.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw PreferenceError.unsafePath }
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 128 * 1024 * 1024 else { throw PreferenceError.malformedProfile(directory.lastPathComponent) }
            let data = try Data(contentsOf: preferences)
            guard let json = try? JSONSerialization.jsonObject(with: data), let object = json as? [String: Any],
                  object["webrtc"] == nil || object["webrtc"] is [String: Any] else {
                throw PreferenceError.malformedProfile(directory.lastPathComponent)
            }
            profiles.append(Profile(url: preferences, data: data, preferences: object))
        }
        return Snapshot(profiles: profiles)
    }

    func initialize(browserIsRunning: () -> Bool) throws {
        guard !browserIsRunning() else { throw PreferenceError.browserRunning }
        let current = try snapshot()
        guard !current.conflictingURLRules else { throw PreferenceError.urlOverrides }
        let changes = current.profiles.filter { !$0.isProtected }
        guard !changes.isEmpty else { return }
        try makePrivateDirectory(backupDirectory)
        let transactionBackup = backupDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(transactionBackup)
        // Finish all backups before changing the first profile.
        for profile in changes {
            guard !browserIsRunning() else { throw PreferenceError.browserRunning }
            let backup = transactionBackup.appendingPathComponent(profile.url.deletingLastPathComponent().lastPathComponent + "-Preferences.json")
            try atomicWrite(profile.data, to: backup)
        }
        var written: [(profile: Profile, replacement: Data)] = []
        do {
            for profile in changes {
                guard !browserIsRunning() else { throw PreferenceError.browserRunning }
                try requireType(profile.url, expected: .typeRegular)
                guard try Data(contentsOf: profile.url) == profile.data else { throw PreferenceError.changedProfile }
                var object = profile.preferences
                var webrtc = object["webrtc"] as? [String: Any] ?? [:]
                webrtc["ip_handling_policy"] = Self.protectedValue
                object["webrtc"] = webrtc
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                guard !browserIsRunning() else { throw PreferenceError.browserRunning }
                try atomicWrite(data, to: profile.url)
                written.append((profile, data))
            }
        } catch {
            // Restore only bytes still owned by this transaction, and only while
            // the browser remains closed. Never overwrite new browser/user edits.
            for entry in written.reversed() {
                guard !browserIsRunning() else { break }
                guard (try? requireType(entry.profile.url, expected: .typeRegular)) != nil,
                      (try? Data(contentsOf: entry.profile.url)) == entry.replacement else { continue }
                try? atomicWrite(entry.profile.data, to: entry.profile.url)
            }
            throw error
        }
    }

    private func rejectSymbolicLinkAncestors(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        guard url.isFileURL, !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw PreferenceError.unsafePath }
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            guard let attributes = try existingAttributes(current) else { continue }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw PreferenceError.unsafePath }
        }
    }

    private func existingAttributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let failure = error as NSError
            if BrowserEnvironmentErrorMapper.isFileAccessError(error) { throw error }
            if (failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code))
                || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOENT)) { return nil }
            throw error
        }
    }

    private func requireType(_ url: URL, expected: FileAttributeType) throws {
        try rejectSymbolicLinkAncestors(url)
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        guard type == expected else { throw PreferenceError.unsafePath }
    }

    private func makePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try requireType(url, expected: .typeDirectory)
        } else {
            let parent = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) { try makePrivateDirectory(parent) }
            try requireType(parent, expected: .typeDirectory)
            try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        try requireType(destination.deletingLastPathComponent(), expected: .typeDirectory)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".account-proxy-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var closed = false
        defer { if !closed { Darwin.close(descriptor) }; try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let result = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if result < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        Darwin.close(descriptor); closed = true
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
