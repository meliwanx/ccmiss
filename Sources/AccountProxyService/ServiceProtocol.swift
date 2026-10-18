import Foundation
import Darwin

struct HelperFailure: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct HelperRequest {
    let command: String
    let configuration: [String: Any]?
    let generation: String?
    let expectedPreviousGeneration: String?
    let endpoint: String?

    static let maximumBytes = 512 * 1024
    static func decode(_ data: Data) throws -> HelperRequest {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "command", "configuration", "generation", "expectedPreviousGeneration", "endpoint"]),
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let command = object["command"] as? String,
              ["status", "apply", "stop", "query"].contains(command) else {
            throw HelperFailure(code: "invalid_request", message: "不支持的服务请求。")
        }
        let generation = object["generation"] as? String
        let previous = object["expectedPreviousGeneration"] as? String
        guard generation == nil || UUID(uuidString: generation!) != nil,
              previous == nil || previous!.isEmpty || UUID(uuidString: previous!) != nil else {
            throw HelperFailure(code: "invalid_generation", message: "配置版本标识无效。")
        }
        let configuration = object["configuration"] as? [String: Any]
        let endpoint = object["endpoint"] as? String
        if command == "apply" && (configuration == nil || generation == nil) {
            throw HelperFailure(code: "invalid_request", message: "应用配置时需要配置内容和版本。")
        }
        if command == "query" && !["configs", "rules", "connections", "proxies"].contains(endpoint ?? "") {
            throw HelperFailure(code: "invalid_endpoint", message: "此服务查询不受支持。")
        }
        return HelperRequest(command: command, configuration: configuration, generation: generation,
                             expectedPreviousGeneration: previous, endpoint: endpoint)
    }
}

struct HelperConfiguration {
    static let group = "Account Proxy Exit"
    static let node = "Account Proxy Active"
    static let upstream = "Account Proxy Upstream"
    static let tunDevice = "utun1998"
    static let allowedTopKeys: Set<String> = ["mode", "ipv6", "log-level", "allow-lan", "mixed-port", "bind-address", "tun", "dns", "proxies", "proxy-groups", "rules", "sniffer", "profile", "tcp-concurrent", "unified-delay", "find-process-mode"]

    static func validated(_ input: [String: Any], controllerPath: String, secret: String) throws -> [String: Any] {
        func reject() throws -> Never { throw HelperFailure(code: "unsafe_configuration", message: "配置包含服务不允许的字段或值。") }
        guard Set(input.keys).isSubset(of: allowedTopKeys), input["mode"] as? String == "rule",
              input["ipv6"] as? Bool == false, input["allow-lan"] as? Bool == false,
              input["mixed-port"] as? Int == 0,
              input["bind-address"] as? String == "127.0.0.1",
              let proxies = input["proxies"] as? [[String: Any]], (1...2).contains(proxies.count),
              let groups = input["proxy-groups"] as? [[String: Any]], groups.count == 1,
              let rules = input["rules"] as? [String], !rules.isEmpty, rules.count < 5000,
              let tun = input["tun"] as? [String: Any],
              let dns = input["dns"] as? [String: Any] else { try reject() }
        let names = proxies.compactMap { $0["name"] as? String }
        guard names.count == proxies.count, Set(names).count == proxies.count,
              Set(names).isSubset(of: [node, upstream]),
              let primary = proxies.first(where: { $0["name"] as? String == node }) else { try reject() }
        let front = proxies.first(where: { $0["name"] as? String == upstream })
        guard validSOCKS(primary, name: node, allowsDialer: front != nil) else { try reject() }
        if let front {
            guard primary["dialer-proxy"] as? String == upstream,
                  validSOCKS(front, name: upstream, allowsDialer: false) || validReality(front) else { try reject() }
        } else if primary["dialer-proxy"] != nil { try reject() }
        let group = groups[0]
        guard Set(group.keys).isSubset(of: ["name", "type", "proxies"]), group["name"] as? String == Self.group,
              group["type"] as? String == "select", group["proxies"] as? [String] == [node] else { try reject() }
        let ruleTypes: Set<String> = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR", "SRC-IP-CIDR6", "DST-PORT", "SRC-PORT", "NETWORK", "AND", "OR", "NOT", "MATCH", "PROCESS-NAME", "PROCESS-PATH"]
        for rule in rules {
            guard rule.utf8.count <= 4096, !rule.contains(where: { $0.isNewline || $0 == "\0" }),
                  let type = rule.split(separator: ",").first, ruleTypes.contains(String(type)),
                  !["RULE-SET", "GEOIP", "GEOSITE", "SCRIPT", "SUB-RULE"].contains(where: { rule.contains($0) }),
                  let target = rule.split(separator: ",").last,
                  [Self.group, "DIRECT", "REJECT", "REJECT-DROP", "no-resolve"].contains(String(target)) else { try reject() }
            if ["PROCESS-NAME", "PROCESS-PATH"].contains(String(type)), !rule.hasSuffix(",DIRECT") { try reject() }
            if target == "no-resolve" {
                let pieces = rule.split(separator: ",")
                guard pieces.count >= 3, [Self.group, "DIRECT", "REJECT", "REJECT-DROP"].contains(String(pieces[pieces.count - 2])) else { try reject() }
            }
        }
        guard Set(tun.keys).isSubset(of: ["enable", "stack", "auto-route", "auto-detect-interface", "strict-route", "dns-hijack"]),
              tun["enable"] as? Bool == true, tun["auto-route"] as? Bool == true,
              tun["auto-detect-interface"] as? Bool == true,
              ["gvisor", "system", "mixed"].contains(tun["stack"] as? String ?? "") else { try reject() }
        let dnsKeys: Set<String> = ["enable", "listen", "ipv6", "enhanced-mode", "fake-ip-range", "fake-ip-filter", "nameserver", "fallback", "fallback-filter", "default-nameserver", "proxy-server-nameserver", "respect-rules", "prefer-h3", "nameserver-policy"]
        guard Set(dns.keys).isSubset(of: dnsKeys), dns["enable"] as? Bool == true,
              dns["listen"] as? String == "127.0.0.1:53", dns["ipv6"] as? Bool == false,
              dns["enhanced-mode"] as? String == "fake-ip",
              let fallbackFilter = dns["fallback-filter"] as? [String: Any],
              Set(fallbackFilter.keys).isSubset(of: ["geoip", "ipcidr", "domain"]),
              fallbackFilter["geoip"] as? Bool == false else { try reject() }
        if let filters = dns["fake-ip-filter"] {
            guard let entries = filters as? [String], entries.count <= 1000,
                  entries.allSatisfy({ $0.utf8.count <= 255 && !$0.contains(":") && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else { try reject() }
        }
        guard fallbackFilter["ipcidr"] is [String], fallbackFilter["domain"] is [String] else { try reject() }
        for key in ["nameserver", "fallback", "default-nameserver", "proxy-server-nameserver"] {
            if let values = dns[key] { guard let entries = values as? [String], entries.count <= 16, entries.allSatisfy(validResolver) else { try reject() } }
        }
        if let policies = dns["nameserver-policy"] {
            guard let object = policies as? [String: Any], object.count <= 100 else { try reject() }
            for (key, values) in object {
                guard key.utf8.count <= 255, !key.contains(":"), !key.contains("/"),
                      let entries = values as? [String], entries.count <= 16, entries.allSatisfy(validResolver) else { try reject() }
            }
        }
        if let sniffer = input["sniffer"] {
            guard let object = sniffer as? [String: Any], Set(object.keys).isSubset(of: ["enable", "force-dns-mapping", "parse-pure-ip", "override-destination", "sniff"]),
                  let sniff = object["sniff"] as? [String: Any], Set(sniff.keys).isSubset(of: ["HTTP", "TLS"]) else { try reject() }
            for (_, value) in sniff {
                guard let protocolOptions = value as? [String: Any], Set(protocolOptions.keys).isSubset(of: ["ports"]) else { try reject() }
            }
        }
        if let profile = input["profile"] {
            guard let object = profile as? [String: Any], Set(object.keys).isSubset(of: ["store-selected", "store-fake-ip"]), object.values.allSatisfy({ ($0 as? Bool) == false }) else { try reject() }
        }
        // No user-controlled paths, providers, controllers, downloads, scripts, or
        // processes survive this allowlist. Force the privileged boundary values.
        var result = input
        var forcedTun = tun
        forcedTun["device"] = tunDevice
        forcedTun["dns-hijack"] = ["any:53", "tcp://any:53"]
        forcedTun["strict-route"] = true
        result["tun"] = forcedTun
        var forcedDNS = dns
        forcedDNS["fake-ip-range"] = "198.18.0.1/16"
        result["dns"] = forcedDNS
        result["external-controller"] = ""
        result["external-controller-unix"] = controllerPath
        result["secret"] = secret
        result["log-level"] = "silent"
        result["profile"] = ["store-selected": false, "store-fake-ip": false]
        result["geodata-mode"] = false
        result["geo-auto-update"] = false
        return result
    }

    private static func validSOCKS(_ proxy: [String: Any], name: String, allowsDialer: Bool) -> Bool {
        var keys: Set<String> = ["name", "type", "server", "port", "username", "password", "udp"]
        if allowsDialer { keys.insert("dialer-proxy") }
        guard Set(proxy.keys).isSubset(of: keys), proxy["name"] as? String == name,
              proxy["type"] as? String == "socks5", let host = proxy["server"] as? String, validHost(host),
              let port = proxy["port"] as? Int, (1...65535).contains(port), proxy["udp"] as? Bool == false else { return false }
        for key in ["username", "password"] {
            if let value = proxy[key] {
                guard let string = value as? String, string.utf8.count <= 1024, !string.contains("\0") else { return false }
            }
        }
        return true
    }

    private static func validReality(_ proxy: [String: Any]) -> Bool {
        let keys: Set<String> = ["name", "type", "server", "port", "uuid", "flow", "encryption", "tls", "skip-cert-verify", "servername", "client-fingerprint", "network", "udp", "reality-opts"]
        guard Set(proxy.keys).isSubset(of: keys), proxy["name"] as? String == upstream, proxy["type"] as? String == "vless",
              let host = proxy["server"] as? String, validHost(host), let port = proxy["port"] as? Int, (1...65535).contains(port),
              let uuid = proxy["uuid"] as? String, UUID(uuidString: uuid) != nil,
              ["", "xtls-rprx-vision"].contains(proxy["flow"] as? String ?? ""),
              proxy["encryption"] as? String == "none", proxy["tls"] as? Bool == true,
              proxy["skip-cert-verify"] as? Bool == false, proxy["network"] as? String == "tcp", proxy["udp"] as? Bool == false,
              let servername = proxy["servername"] as? String, validHost(servername), !servername.contains(":"),
              ["chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"].contains(proxy["client-fingerprint"] as? String ?? ""),
              let reality = proxy["reality-opts"] as? [String: Any], Set(reality.keys) == ["public-key", "short-id"],
              let publicKey = reality["public-key"] as? String, publicKey.range(of: #"^[A-Za-z0-9_-]{43}=?$"#, options: .regularExpression) != nil,
              let shortID = reality["short-id"] as? String, shortID.count <= 16, shortID.count % 2 == 0,
              shortID.range(of: #"^[a-fA-F0-9]*$"#, options: .regularExpression) != nil else { return false }
        let base64 = publicKey.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64.padding(toLength: ((base64.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        return Data(base64Encoded: padded)?.count == 32
    }

    private static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && host.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) } && !host.hasPrefix("-")
    }
    private static func validResolver(_ value: String) -> Bool {
        guard value.utf8.count <= 512, !value.contains(where: { $0.isNewline || $0 == "\0" }) else { return false }
        if validHost(value), value.contains(".") || value.contains(":") { return true }
        if value.hasSuffix("#DIRECT") {
            let address = String(value.dropLast(7))
            let parts = address.split(separator: ".").compactMap { Int($0) }
            if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }),
               parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168) { return true }
        }
        guard value.hasPrefix("https://"), let components = URLComponents(string: value), components.user == nil, components.password == nil,
              let host = components.host, validHost(host), !host.isEmpty else { return false }
        return components.fragment == nil || [group, "DIRECT"].contains(components.fragment!)
    }
}

/// Shared pure decision used by the watchdog and isolated tests. A system-wide
/// TUN must never continue carrying another console user's account traffic.
enum ServiceOwnerSessionDecision: Equatable {
    case unchanged, pause, resume
    static func decide(ownerUID: uid_t?, consoleUID: uid_t?, running: Bool, activeIntent: Bool) -> ServiceOwnerSessionDecision {
        if running && ownerUID != consoleUID { return .pause }
        if !running && activeIntent, let owner = ownerUID, owner == consoleUID { return .resume }
        return .unchanged
    }
}

enum DNSRestorationStatus {
    static func isPending(hasBackup: Bool, running: Bool, activeIntent: Bool, ownerUID: uid_t?, consoleUID: uid_t?) -> Bool {
        hasBackup && (!running || !activeIntent || ownerUID != consoleUID)
    }
}

/// Signature validity is established by the native authorizer. The generic
/// interpreter is trusted only as a direct child of the signed fixed main app.
enum HelperPeerOriginPolicy {
    static func isAllowed(clientPath: String, parentPath: String?, applicationPath: String, parentSignatureValid: Bool) -> Bool {
        let app = URL(fileURLWithPath: applicationPath)
        let main = app.appendingPathComponent("Contents/MacOS/AccountProxySwitcher").path
        if clientPath == main { return true }
        let node = app.appendingPathComponent("Contents/Resources/node").path
        return clientPath == node && parentPath == main && parentSignatureValid
    }
}
