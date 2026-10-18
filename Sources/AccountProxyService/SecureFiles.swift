import Foundation
import Darwin
import CryptoKit

struct ServicePaths {
    let runtime: URL
    let socketDirectory: URL
    let bundledCore: URL
    var controlSocket: URL { socketDirectory.appendingPathComponent("control.sock") }
    var coreSocket: URL { runtime.appendingPathComponent("core.sock") }
    var core: URL { runtime.appendingPathComponent("mihomo") }
    var configuration: URL { runtime.appendingPathComponent("config.json") }
    var state: URL { runtime.appendingPathComponent("state.json") }
    var dnsBackup: URL { runtime.appendingPathComponent("dns-backup.plist") }

    static func bundleRoot(helperExecutable: URL) throws -> URL {
        let bundle = helperExecutable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app", bundle.deletingLastPathComponent().path == "/Applications",
              helperExecutable.path == bundle.appendingPathComponent("Contents/Library/HelperTools/AccountProxyService").path else {
            throw HelperFailure(code: "invalid_installation", message: "请将应用安装在 /Applications 后再授权系统服务。")
        }
        return bundle
    }

    static func production() throws -> ServicePaths {
        var executablePath = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getpid(), &executablePath, UInt32(executablePath.count)) > 0 else {
            throw HelperFailure(code: "invalid_installation", message: "无法确认系统服务可执行文件路径。")
        }
        let bundle = try bundleRoot(helperExecutable: URL(fileURLWithPath: String(cString: executablePath)))
        return ServicePaths(runtime: URL(fileURLWithPath: "/Library/Application Support/AccountProxySwitcherService"),
                            socketDirectory: URL(fileURLWithPath: "/var/run/account-proxy-switcher"),
                            bundledCore: bundle.appendingPathComponent("Contents/Resources/mihomo"))
    }
}

struct SecureServiceFiles {
    let owner: uid_t
    func directory(_ url: URL, mode: mode_t = 0o700) throws {
        try rejectLinks(url)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == owner else { throw failure() }
        } else {
            guard Darwin.mkdir(url.path, mode) == 0 else { throw failure() }
        }
        guard chmod(url.path, mode) == 0 else { throw failure() }
    }
    func read(_ url: URL, maximum: Int = 1024 * 1024) throws -> Data {
        try rejectLinks(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var statbuf = stat()
        guard fstat(fd, &statbuf) == 0, (statbuf.st_mode & S_IFMT) == S_IFREG,
              statbuf.st_uid == owner, statbuf.st_size >= 0, statbuf.st_size <= maximum else { throw failure() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }
    func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        try rejectLinks(url)
        let parent = url.deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == owner else { throw failure() }
        let temporary = parent.appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw failure() }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure() }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw failure() }
    }
    func stageCore(from source: URL, to target: URL, expectedHash: String) throws {
        guard expectedHash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw HelperFailure(code: "core_identity_missing", message: "服务尚未包含经过验证的网络核心版本。")
        }
        try rejectLinks(source)
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size > 0, metadata.st_size < 200 * 1024 * 1024 else { throw failure() }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else { throw HelperFailure(code: "core_identity_mismatch", message: "网络核心文件校验失败，已拒绝启动。") }
        if let existing = try? read(target, maximum: 200 * 1024 * 1024), existing == data {
            guard chmod(target.path, 0o700) == 0 else { throw failure() }
            return
        }
        try write(data, to: target, mode: 0o700)
    }
    func rejectLinks(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/")
        // /var is Apple's immutable alias of /private/var. No other symlink is
        // permitted, including user-writable app/runtime path components.
        for part in url.pathComponents.dropFirst() {
            current.appendPathComponent(part)
            if current.path == "/var" { current = URL(fileURLWithPath: "/private/var"); continue }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw failure() }
        }
    }
    private func failure() -> HelperFailure { HelperFailure(code: "unsafe_runtime", message: "服务文件路径、所有者或权限不符合要求。") }
}
