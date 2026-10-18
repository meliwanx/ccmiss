import Foundation
import SystemConfiguration
import Darwin

struct ServiceConflictDetector {
    let ownedCore: String
    func conflicts(ownCoreRunning: Bool) -> [String] {
        var conflicts: [String] = []
        if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any],
           ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"].contains(where: { (proxies[$0] as? NSNumber)?.boolValue == true }) {
            conflicts.append("系统已启用其他代理设置")
        }
        for pid in allProcessIDs() where pid != getpid() {
            let path = processPath(pid)
            if path.isEmpty || path == ownedCore { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            if ["mihomo", "clash", "sing-box", "surge", "tailscaled", "openvpn", "wireguard", "v2ray", "xray"].contains(where: { name.contains($0) }) {
                conflicts.append("其他代理客户端正在运行")
                break
            }
        }
        var first: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&first) == 0, let start = first {
            defer { freeifaddrs(start) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = start
            while let current = cursor {
                defer { cursor = current.pointee.ifa_next }
                let interface = current.pointee
                guard let rawName = interface.ifa_name, let address = interface.ifa_addr,
                      interface.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
                let name = String(cString: rawName)
                if address.pointee.sa_family == UInt8(AF_INET6), name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("bond") {
                    let ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    let firstByte = withUnsafeBytes(of: ipv6) { $0.first ?? 0 }
                    if firstByte & 0xe0 == 0x20 { conflicts.append("物理网络仍有公网 IPv6；此版本需先手动关闭 IPv6 才能保证统一出口") }
                }
                let isTunnel = ["utun", "tun", "tap", "ppp", "ipsec"].contains(where: { name.hasPrefix($0) })
                var hasPublicIPv6 = false
                if address.pointee.sa_family == UInt8(AF_INET6) {
                    let ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    hasPublicIPv6 = withUnsafeBytes(of: ipv6) { ($0.first ?? 0) & 0xe0 == 0x20 }
                }
                if (address.pointee.sa_family == UInt8(AF_INET) || hasPublicIPv6), isTunnel && !(ownCoreRunning && name == HelperConfiguration.tunDevice) {
                    conflicts.append("已有活跃 TUN 接口 \(name)")
                }
            }
        }
        return Array(Set(conflicts)).sorted()
    }
    func ownsTunnel() -> Bool {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return false }
        defer { freeifaddrs(start) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let interface = current.pointee
            if let name = interface.ifa_name, let address = interface.ifa_addr,
               String(cString: name) == HelperConfiguration.tunDevice,
               address.pointee.sa_family == UInt8(AF_INET), interface.ifa_flags & UInt32(IFF_UP) != 0 { return true }
        }
        return false
    }
    func requireDNSPortAvailable() throws {
        for type in [SOCK_DGRAM, SOCK_STREAM] {
            let fd = socket(AF_INET, type, 0)
            guard fd >= 0 else { throw HelperFailure(code: "dns_port_unavailable", message: "无法检查本机 DNS 端口。") }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(53).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard result == 0 else { throw HelperFailure(code: "dns_port_in_use", message: "127.0.0.1:53 已被占用；已保留当前 DNS 和网络。") }
        }
    }
}
