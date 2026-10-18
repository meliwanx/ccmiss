import Foundation
import Security
import SystemConfiguration
import Darwin

struct ServiceAuthorization {
    let application: URL
    let teamIdentifier: String

    func validateInstallation() throws {
        guard teamIdentifier.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { throw failure() }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess, let code else { throw failure() }
        let requirement = try self.requirement(identifier: "io.ccmiss.app")
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else { throw failure() }
    }
    func peer(_ socket: Int32, ownerUID: uid_t?) throws -> uid_t {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0, uid >= 500,
              consoleUID() == uid, ownerUID == nil || ownerUID == uid else {
            throw HelperFailure(code: "unauthorized_peer", message: "此服务只允许已初始化的当前登录用户控制。")
        }
        var pid: pid_t = 0, size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { throw failure() }
        let path = processPath(pid)
        let identifier: String
        if path == application.appendingPathComponent("Contents/MacOS/AccountProxySwitcher").path { identifier = "io.ccmiss.app" }
        else if path == application.appendingPathComponent("Contents/Resources/node").path { identifier = "io.ccmiss.app.runtime" }
        else { throw failure() }
        try validateProcess(pid, identifier: identifier)
        let mainPath = application.appendingPathComponent("Contents/MacOS/AccountProxySwitcher").path
        var parentPath: String?
        var parentSignatureValid = false
        if identifier == "io.ccmiss.app.runtime" {
            var info = proc_bsdinfo()
            let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard bytes == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_uid == uid,
                  info.pbi_ppid > 1, info.pbi_ppid <= UInt32(Int32.max) else { throw originFailure() }
            let parent = pid_t(info.pbi_ppid)
            parentPath = processPath(parent)
            guard parentPath == mainPath else { throw originFailure() }
            try validateProcess(parent, identifier: "io.ccmiss.app")
            parentSignatureValid = true
        }
        guard HelperPeerOriginPolicy.isAllowed(clientPath: path, parentPath: parentPath,
                                                applicationPath: application.path,
                                                parentSignatureValid: parentSignatureValid) else { throw originFailure() }
        return uid
    }
    func consoleUID() -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?, name != "loginwindow", uid >= 500 else { return nil }
        return uid
    }
    private func validateProcess(_ pid: pid_t, identifier: String) throws {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), try requirement(identifier: identifier)) == errSecSuccess else { throw failure() }
    }
    private func originFailure() -> HelperFailure {
        HelperFailure(code: "unauthorized_parent", message: "仅允许由 ccmiss 主应用启动的组件控制系统网络服务。")
    }
    private func requirement(identifier: String) throws -> SecRequirement {
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" and identifier \"\(identifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { throw failure() }
        return requirement
    }
    private func failure() -> HelperFailure { HelperFailure(code: "signature_required", message: "系统网络服务需要受信任且签名匹配的正式应用；当前开发签名或安装文件不符合要求。") }
}

func processPath(_ pid: pid_t) -> String {
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return "" }
    return String(cString: path)
}

func allProcessIDs() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 128)
    let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return filled > 0 ? Array(pids.prefix(Int(filled))) : []
}
