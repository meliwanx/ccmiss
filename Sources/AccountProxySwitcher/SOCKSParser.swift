import Foundation
import Darwin

/// These errors deliberately omit input, because a proxy URL can contain a password.
enum SOCKSURIError: LocalizedError, Equatable {
    case invalidScheme
    case invalidFormat
    case invalidCredentials
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidScheme: return "请输入以 socks5:// 或 socks5h:// 开头的代理地址。"
        case .invalidFormat: return "代理地址格式不正确；不支持路径、查询参数或片段。"
        case .invalidCredentials: return "代理用户名或密码格式不正确；特殊字符可使用百分号编码。"
        case .invalidHost: return "代理服务器地址不正确；IPv6 地址需放在方括号内。"
        case .invalidPort: return "代理端口必须是 1 到 65535 之间的整数。"
        }
    }
}

extension SOCKSProxy {
    init(uri: String) throws {
        let value = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 32_768,
              let separator = value.range(of: "://") else {
            throw SOCKSURIError.invalidScheme
        }
        let scheme = value[..<separator.lowerBound].lowercased()
        guard scheme == "socks5" || scheme == "socks5h" else {
            throw SOCKSURIError.invalidScheme
        }
        let authority = String(value[separator.upperBound...])
        guard !authority.isEmpty,
              !authority.contains(where: { "/?#".contains($0) || $0.isWhitespace || $0.isNewline }),
              !authority.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SOCKSURIError.invalidFormat
        }

        let parts = authority.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw SOCKSURIError.invalidCredentials }
        var parsedUsername: String?
        var parsedPassword: String?
        let server: String
        if parts.count == 2 {
            let userInfo = parts[0]
            let credentials = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            parsedUsername = try Self.decodeCredential(String(credentials[0]), allowEmpty: false)
            if credentials.count == 2 {
                parsedPassword = try Self.decodeCredential(String(credentials[1]), allowEmpty: true)
            }
            server = String(parts[1])
        } else {
            server = String(parts[0])
        }

        let rawHost: String
        let rawPort: String
        if server.hasPrefix("[") {
            guard let endBracket = server.firstIndex(of: "]") else { throw SOCKSURIError.invalidHost }
            rawHost = String(server[server.index(after: server.startIndex)..<endBracket])
            let remainder = server[server.index(after: endBracket)...]
            guard remainder.hasPrefix(":"), remainder.count > 1 else { throw SOCKSURIError.invalidPort }
            rawPort = String(remainder.dropFirst())
            var address = in6_addr()
            guard rawHost.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                throw SOCKSURIError.invalidHost
            }
        } else {
            let serverParts = server.split(separator: ":", omittingEmptySubsequences: false)
            guard serverParts.count == 2 else { throw SOCKSURIError.invalidHost }
            rawHost = String(serverParts[0])
            rawPort = String(serverParts[1])
            try Self.validateDomainOrIPv4(rawHost)
        }
        guard !rawPort.isEmpty,
              rawPort.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let parsedPort = Int(rawPort), (1...65_535).contains(parsedPort) else {
            throw SOCKSURIError.invalidPort
        }
        var normalizedHost = rawHost.lowercased()
        if rawHost.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            // Avoid leading-zero/octal interpretations differing between clients.
            normalizedHost = rawHost.split(separator: ".").compactMap { Int($0) }.map(String.init).joined(separator: ".")
        }
        self.init(host: normalizedHost, port: parsedPort, username: parsedUsername, password: parsedPassword)
    }

    /// Canonical URLs always use socks5; hostnames stay remote-resolved by the local engine.
    var canonicalURI: String {
        var authentication = ""
        if let username {
            authentication = Self.encodeCredential(username)
            if let password { authentication += ":" + Self.encodeCredential(password) }
            authentication += "@"
        }
        let server = host.contains(":") ? "[\(host)]" : host
        return "socks5://\(authentication)\(server):\(port)"
    }

    private static func decodeCredential(_ value: String, allowEmpty: Bool) throws -> String {
        guard let decoded = value.removingPercentEncoding,
              (allowEmpty || !decoded.isEmpty), decoded.utf8.count <= 255,
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SOCKSURIError.invalidCredentials
        }
        return decoded
    }

    private static func encodeCredential(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func validateDomainOrIPv4(_ host: String) throws {
        guard !host.isEmpty, host.utf8.count <= 254 else { throw SOCKSURIError.invalidHost }
        let domain = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !domain.isEmpty, domain.utf8.count <= 253 else { throw SOCKSURIError.invalidHost }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let numericAddress = domain.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
        if numericAddress {
            guard labels.count == 4,
                  labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 3 && Int($0).map { (0...255).contains($0) } == true }) else {
                throw SOCKSURIError.invalidHost
            }
            return
        }
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else {
                throw SOCKSURIError.invalidHost
            }
        }
    }
}
