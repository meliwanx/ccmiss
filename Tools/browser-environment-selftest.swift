import Foundation
import Darwin

@main
struct BrowserEnvironmentSelfTest {
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        guard condition else { fatalError("FAILED: \(label)") }
    }
    static func mustThrow(_ label: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAILED: \(label)") } catch { checks += 1 }
    }
    static func main() throws {
        let fm = FileManager.default
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("BrowserEnvironmentSelfTest-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        func fixture(_ name: String) throws -> ChromiumWebRTCPreferences {
            let root = temporary.appendingPathComponent(name)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            return ChromiumWebRTCPreferences(rootDirectory: root, backupDirectory: temporary.appendingPathComponent(name + "-backups"))
        }
        func profile(_ store: ChromiumWebRTCPreferences, _ directory: String, _ object: [String: Any]) throws -> URL {
            let folder = store.rootDirectory.appendingPathComponent(directory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("Preferences")
            try JSONSerialization.data(withJSONObject: object).write(to: path)
            return path
        }
        let missing = ChromiumWebRTCPreferences(rootDirectory: temporary.appendingPathComponent("missing"), backupDirectory: temporary.appendingPathComponent("unused"))
        expect(try missing.snapshot().profiles.isEmpty, "missing browser profiles are not created")

        let normal = try fixture("normal")
        let first = try profile(normal, "Default", ["marker": ["preserve": [1,2,3]], "webrtc": ["other": "keep"]])
        let second = try profile(normal, "Profile 4", ["marker": "second"])
        _ = try profile(normal, "System Profile", ["marker": "system"])
        expect(try normal.snapshot().profiles.count == 2, "system profile excluded")
        let firstOriginal = try Data(contentsOf: first)
        let secondOriginal = try Data(contentsOf: second)
        mustThrow("running browser is never modified") { try normal.initialize { true } }
        expect(try Data(contentsOf: first) == firstOriginal, "no write while running")
        expect(!fm.fileExists(atPath: normal.backupDirectory.path), "no backup side effect while running")
        try normal.initialize { false }
        expect(try normal.snapshot().protectedCount == 2, "all regular profiles protected")
        let changed = try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as! [String: Any]
        expect((changed["webrtc"] as? [String: Any])?["other"] as? String == "keep", "other WebRTC settings preserved")
        expect((changed["marker"] as? [String: Any])?["preserve"] as? [Int] == [1,2,3], "unrelated nested settings preserved")
        let mode = try fm.attributesOfItem(atPath: first.path)[.posixPermissions] as! NSNumber
        expect(mode.intValue == 0o600, "profile write private")
        let backupMode = try fm.attributesOfItem(atPath: normal.backupDirectory.path)[.posixPermissions] as! NSNumber
        expect(backupMode.intValue == 0o700, "backup directory private")
        let backupFolders = try fm.contentsOfDirectory(at: normal.backupDirectory, includingPropertiesForKeys: nil)
        let backupFiles = try fm.contentsOfDirectory(at: backupFolders[0], includingPropertiesForKeys: nil)
        expect(backupFiles.count == 2, "all backups precede writes")
        expect(try Data(contentsOf: backupFolders[0].appendingPathComponent("Default-Preferences.json")) == firstOriginal, "original bytes recoverable")
        expect(try Data(contentsOf: backupFolders[0].appendingPathComponent("Profile 4-Preferences.json")) == secondOriginal, "second original bytes recoverable")
        try normal.initialize { false }
        expect(try fm.contentsOfDirectory(atPath: normal.backupDirectory.path).count == 1, "ready configuration is idempotent")

        let corrupt = try fixture("corrupt")
        let corruptPath = try profile(corrupt, "Default", [:])
        try Data("{ broken ".utf8).write(to: corruptPath)
        mustThrow("invalid JSON retained") { try corrupt.initialize { false } }
        expect(try String(contentsOf: corruptPath, encoding: .utf8) == "{ broken ", "invalid bytes untouched")
        let overridden = try fixture("overridden")
        _ = try profile(overridden, "Default", ["webrtc": ["ip_handling_url": [["url":"*", "handling":"default"]]]])
        mustThrow("URL overrides not silently changed") { try overridden.initialize { false } }

        let symlink = try fixture("symlink")
        let symlinkPath = try profile(symlink, "Default", [:])
        try fm.removeItem(at: symlinkPath)
        try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: first)
        mustThrow("symlink preference rejected") { _ = try symlink.snapshot() }
        let parentLink = temporary.appendingPathComponent("parent-link")
        try fm.createSymbolicLink(at: parentLink, withDestinationURL: normal.rootDirectory)
        let symlinkStore = ChromiumWebRTCPreferences(rootDirectory: parentLink, backupDirectory: temporary.appendingPathComponent("link-backup"))
        mustThrow("symlink profile root rejected") { _ = try symlinkStore.snapshot() }
        let linkBackupStore = try fixture("backup-symlink")
        _ = try profile(linkBackupStore, "Default", [:])
        try fm.createSymbolicLink(at: linkBackupStore.backupDirectory, withDestinationURL: normal.backupDirectory)
        mustThrow("symlink backup rejected") { try linkBackupStore.initialize { false } }

        let race = try fixture("race")
        let raceFirst = try profile(race, "Default", ["before": "first"])
        let raceSecond = try profile(race, "Profile 1", ["before": "second"])
        let raceOriginal = try Data(contentsOf: raceFirst)
        let concurrent = try JSONSerialization.data(withJSONObject: ["concurrent": "user change"])
        var calls = 0
        mustThrow("concurrent edit aborts transaction") {
            try race.initialize {
                calls += 1
                if calls == 6 { try! concurrent.write(to: raceSecond) }
                return false
            }
        }
        expect(try Data(contentsOf: raceFirst) == raceOriginal, "earlier profile rolled back")
        expect(try Data(contentsOf: raceSecond) == concurrent, "concurrent edits preserved")
        let resumed = try fixture("browser-started")
        let resumedFirst = try profile(resumed, "Default", ["before": "first"])
        let resumedSecond = try profile(resumed, "Profile 1", ["before": "second"])
        let resumedOriginal = try Data(contentsOf: resumedSecond)
        var runningCalls = 0
        mustThrow("browser starting during transaction stops writes") {
            try resumed.initialize {
                runningCalls += 1
                return runningCalls >= 6
            }
        }
        expect(try resumed.snapshot().protectedCount == 1, "running browser is not overwritten during rollback")
        expect(try Data(contentsOf: resumedSecond) == resumedOriginal, "remaining profile remains untouched")
        expect(try JSONSerialization.jsonObject(with: Data(contentsOf: resumedFirst)) is [String: Any], "partially written profile remains valid")
        try resumed.initialize { false }
        expect(try resumed.snapshot().protectedCount == 2, "next initialization completes safely")
        for error in [
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        ] {
            let status = BrowserEnvironmentErrorMapper.status(for: error, browserName: "Google Chrome", isBrowserRunning: true)
            expect(status.state == .needsAction && status.requiresFileAccess, "permission error requires user file authorization")
            expect(status.summary == "需要浏览器配置文件访问权限", "permission summary actionable")
            expect(status.totalProfileCount == 0 && status.protectedProfileCount == 0, "permission failures never claim visible coverage")
            expect(status.details.contains("完全磁盘访问权限") && status.details.contains("重新打开本应用") && status.details.contains("不是钥匙串密码"), "permission instructions identify macOS access")
            expect(!status.canInitialize && status.isBrowserRunning, "permission gate does not suggest browser write")
        }
        let ordinary = BrowserEnvironmentErrorMapper.status(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)), browserName: "Chrome", isBrowserRunning: false)
        expect(ordinary.state == .error && !ordinary.requiresFileAccess, "unrelated errors do not request file access")
        let roundTrip = try JSONDecoder().decode(BrowserEnvironmentStatus.self, from: JSONEncoder().encode(ordinary))
        expect(roundTrip == ordinary, "permission status is codable")
        print("Browser environment offline checks passed: \(checks)")
    }
}
