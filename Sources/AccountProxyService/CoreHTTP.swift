import Foundation
import Darwin

struct CoreHTTP {
    let socketPath: String
    let secret: String
    func request(_ method: String = "GET", _ path: String, body: Data? = nil) throws -> [String: Any] {
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw unavailable() }
        defer { close(socketFD) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw unavailable() }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw unavailable() }
        let content = body ?? Data()
        let header = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(secret)\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(content.count)\r\n\r\n"
        var request = Data(header.utf8); request.append(content)
        try sendAll(request, socket: socketFD)
        var response = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = recv(socketFD, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, response.count + count <= 4 * 1024 * 1024 else { throw unavailable() }
            response.append(contentsOf: buffer.prefix(count))
        }
        guard let delimiter = response.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: response[..<delimiter.lowerBound], encoding: .utf8),
              let status = headers.split(separator: " ").dropFirst().first.flatMap({ Int($0) }), (200...299).contains(status) else { throw unavailable() }
        var payload = Data(response[delimiter.upperBound...])
        if headers.lowercased().contains("transfer-encoding: chunked") { payload = try decodeChunks(payload) }
        if payload.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw unavailable() }
        return object
    }
    private func decodeChunks(_ data: Data) throws -> Data {
        var remaining = data, result = Data()
        while let delimiter = remaining.range(of: Data("\r\n".utf8)), let line = String(data: remaining[..<delimiter.lowerBound], encoding: .ascii),
              let count = Int(line.split(separator: ";").first.map(String.init) ?? "", radix: 16) {
            if count == 0 { return result }
            let start = delimiter.upperBound
            guard count >= 0, remaining.distance(from: start, to: remaining.endIndex) >= count + 2 else { throw unavailable() }
            let end = remaining.index(start, offsetBy: count)
            result.append(remaining[start..<end])
            remaining = Data(remaining[remaining.index(end, offsetBy: 2)...])
        }
        throw unavailable()
    }
    private func unavailable() -> HelperFailure { HelperFailure(code: "core_unavailable", message: "网络核心尚未就绪或返回了无效响应。") }
}

func sendAll(_ data: Data, socket: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = send(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw HelperFailure(code: "socket_failed", message: "无法发送服务响应。") }
            offset += count
        }
    }
}
