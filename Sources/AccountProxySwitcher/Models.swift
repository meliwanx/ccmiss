import Foundation

/// Only non-secret profile metadata is persisted to the profile list.
struct ProxyProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var accountDescription: String
    var host: String
    var port: Int
    var username: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        accountDescription: String,
        host: String,
        port: Int,
        username: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.accountDescription = accountDescription
        self.host = host
        self.port = port
        self.username = username
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var endpoint: String {
        let address = host.contains(":") ? "[\(host)]" : host
        return "\(address):\(port)"
    }

    var displayDescription: String {
        accountDescription.isEmpty ? "未填写账号描述" : accountDescription
    }
}

/// An in-memory representation of a SOCKS5 endpoint. Credentials are kept in the app’s owner-only local data file.
struct SOCKSProxy: Equatable {
    var host: String
    var port: Int
    var username: String?
    var password: String?

    init(host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

enum ProxyMode: String, CaseIterable, Identifiable {
    case system
    case profile

    var id: String { rawValue }
    var title: String { self == .system ? "跟随系统代理" : "使用配置" }
}

enum RoutingScope: String, Codable, CaseIterable, Identifiable {
    case fullPublic
    case servicesOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullPublic: return "公网（保留直连）"
        case .servicesOnly: return "指定服务"
        }
    }

    var subtitle: String {
        switch self {
        case .fullPublic: return "公网 TCP 使用所选出口，保留直连例外"
        case .servicesOnly: return "Claude · Cloudflare · Stripe"
        }
    }

    var explanation: String {
        switch self {
        case .fullPublic:
            return "公网 TCP 经所选 SOCKS5 出口；局域网及本应用明确配置的直连例外保留。受管公网 UDP 受限，部分语音、视频通话或游戏可能受影响。"
        case .servicesOnly:
            return "Claude、Cloudflare、Stripe 及已覆盖的相关域名使用所选出口。有 IP 白名单的服务需先放行所选出口。"
        }
    }
}

struct EngineStatus: Equatable {
    var isRunning: Bool
    var tunEnabled: Bool
    var mode: String
    var message: String
    var needsReapply: Bool

    init(isRunning: Bool = false, tunEnabled: Bool = false, mode: String = "未知", message: String = "正在检查网络环境…", needsReapply: Bool = false) {
        self.isRunning = isRunning
        self.tunEnabled = tunEnabled
        self.mode = mode
        self.message = message
        self.needsReapply = needsReapply
    }

    var isOperational: Bool { isRunning && tunEnabled && !needsReapply }
}

struct ExitVerification: Codable, Equatable {
    var ip: String?
    var expectedIP: String
    var checkedAt: Date
    var success: Bool
    var details: String

    init(ip: String?, expectedIP: String, checkedAt: Date = Date(), success: Bool, details: String) {
        self.ip = ip
        self.expectedIP = expectedIP
        self.checkedAt = checkedAt
        self.success = success
        self.details = details
    }
}
