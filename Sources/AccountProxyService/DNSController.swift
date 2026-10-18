import Foundation
import SystemConfiguration
import Darwin

/// The original DNS protocol dictionaries are saved before any persistent write.
/// Restore only ServerAddresses when that value still belongs to this service;
/// search domains and unrelated changes made by other apps/users remain intact.
enum DNSRestoration {
    static func restore(current: [String: Any]?, original: [String: Any]?) -> [String: Any]? {
        guard let current = current, current["ServerAddresses"] as? [String] == ["127.0.0.1"] else { return current }
        var restored = current
        if let originalAddresses = original?["ServerAddresses"] { restored["ServerAddresses"] = originalAddresses }
        else { restored.removeValue(forKey: "ServerAddresses") }
        return restored.isEmpty ? nil : restored
    }
}

enum DNSOwnershipAction: Equatable {
    case unchanged, takeover, externalChange
    static func plan(current: [String: Any]?, wasCaptured: Bool) -> DNSOwnershipAction {
        if current?["ServerAddresses"] as? [String] == ["127.0.0.1"] { return .unchanged }
        return wasCaptured ? .externalChange : .takeover
    }
}

final class DNSController {
    let backupURL: URL
    let files: SecureServiceFiles
    init(backupURL: URL, files: SecureServiceFiles) { self.backupURL = backupURL; self.files = files }

    func apply() throws {
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, false) else { throw failure() }
        defer { SCPreferencesUnlock(prefs) }
        let services = activePhysicalServices(prefs)
        guard !services.isEmpty else { throw HelperFailure(code: "no_uplink", message: "尚未找到活跃的物理网络连接。") }
        var backup = try loadBackup()
        var records = backup["services"] as? [[String: Any]] ?? []
        let known = Set(records.compactMap { $0["id"] as? String })
        var changes: [(SCNetworkProtocol, [String: Any])] = []
        let originalCount = records.count
        for service in services {
            guard let identifier = SCNetworkServiceGetServiceID(service) as String?,
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { throw failure() }
            let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any]
            let action = DNSOwnershipAction.plan(current: current, wasCaptured: known.contains(identifier))
            if action == .externalChange {
                throw HelperFailure(code: "external_dns_change", message: "系统 DNS 已被其他应用或用户修改；已停止本应用接管并保留外部设置。")
            }
            if !known.contains(identifier) {
                records.append(["id": identifier, "hadConfiguration": current != nil, "original": current ?? [:]])
            }
            if action == .takeover {
                var configuration = current ?? [:]
                configuration["ServerAddresses"] = ["127.0.0.1"]
                changes.append((proto, configuration))
            }
        }
        // Healthy monitoring is read-only. New snapshots are durable before
        // changing DNS; a stable network never triggers periodic commit/apply.
        if records.count != originalCount {
            backup = ["version": 1, "services": records]
            try files.write(PropertyListSerialization.data(fromPropertyList: backup, format: .binary, options: 0), to: backupURL)
        }
        guard !changes.isEmpty else { return }
        for (proto, configuration) in changes {
            guard SCNetworkProtocolSetConfiguration(proto, configuration as CFDictionary) else { throw failure() }
        }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else { throw failure() }
    }

    func restoreIfOwned() throws {
        let backup = try loadBackup()
        guard let records = backup["services"] as? [[String: Any]], !records.isEmpty else { return }
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, false) else { throw failure() }
        defer { SCPreferencesUnlock(prefs) }
        var changed = false
        for record in records {
            guard let identifier = record["id"] as? String, UUID(uuidString: identifier) != nil,
                  let service = SCNetworkServiceCopy(prefs, identifier as CFString),
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { continue }
            let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any]
            guard current?["ServerAddresses"] as? [String] == ["127.0.0.1"] else { continue }
            let original = record["hadConfiguration"] as? Bool == true ? record["original"] as? [String: Any] : nil
            let restored = DNSRestoration.restore(current: current, original: original)
            guard SCNetworkProtocolSetConfiguration(proto, restored as CFDictionary?) else { throw failure() }
            changed = true
        }
        if changed {
            guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else { throw failure() }
        }
        if unlink(backupURL.path) != 0 && errno != ENOENT { throw failure() }
    }

    private func preferences() throws -> SCPreferences {
        guard let prefs = SCPreferencesCreate(nil, "Account Proxy Switcher DNS" as CFString, nil) else { throw failure() }
        return prefs
    }
    private func activePhysicalServices(_ prefs: SCPreferences) -> [SCNetworkService] {
        guard let store = SCDynamicStoreCreate(nil, "Account Proxy Switcher" as CFString, nil, nil),
              let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [] }
        return all.filter { service in
            guard SCNetworkServiceGetEnabled(service), let interface = SCNetworkServiceGetInterface(service),
                  let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("bond") else { return false }
            guard let identifier = SCNetworkServiceGetServiceID(service) as String? else { return false }
            let key = "State:/Network/Service/\(identifier)/IPv4"
            guard let state = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let addresses = state["Addresses"] as? [String], !addresses.isEmpty else { return false }
            return true
        }
    }
    private func loadBackup() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return [:] }
        let data = try files.read(backupURL)
        guard let backup = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              backup["version"] as? Int == 1, let records = backup["services"] as? [[String: Any]], records.count <= 64 else { throw failure() }
        return backup
    }
    private func failure() -> HelperFailure { HelperFailure(code: "dns_configuration_failed", message: "无法安全保存或恢复系统 DNS；服务不会覆盖外部改动。") }
}
