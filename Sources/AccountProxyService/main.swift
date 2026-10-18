import Foundation
import Darwin

func createControlSocket(_ paths: ServicePaths, files: SecureServiceFiles) throws -> Int32 {
    try files.rejectLinks(paths.controlSocket)
    if let attributes = try? FileManager.default.attributesOfItem(atPath: paths.controlSocket.path) {
        guard attributes[.type] as? FileAttributeType == .typeSocket,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == 0 else { throw HelperFailure(code: "unsafe_socket", message: "服务套接字所有者不符合要求。") }
        // launchd runs one instance. A leftover socket is removed only after
        // refusing paths other than a root-owned Unix socket in our own folder.
        unlink(paths.controlSocket.path)
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HelperFailure(code: "socket_failed", message: "无法创建服务套接字。") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(paths.controlSocket.path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(descriptor); throw HelperFailure(code: "socket_failed", message: "服务路径过长。") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let result = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard result == 0, chmod(paths.controlSocket.path, 0o666) == 0, listen(descriptor, 16) == 0 else { close(descriptor); throw HelperFailure(code: "socket_failed", message: "服务控制端口无法就绪。") }
    return descriptor
}

func readRequest(_ descriptor: Int32) throws -> Data {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count < 0 && errno == EINTR { continue }
        guard count > 0, data.count + count <= HelperRequest.maximumBytes else { throw HelperFailure(code: "invalid_request", message: "服务请求不完整或超过大小限制。") }
        data.append(contentsOf: buffer.prefix(count))
        if let newline = data.firstIndex(of: 10) {
            guard data[data.index(after: newline)...].allSatisfy({ [9, 10, 13, 32].contains($0) }) else { throw HelperFailure(code: "invalid_request", message: "每个连接只接受一个服务请求。") }
            return Data(data[..<newline])
        }
    }
}

// There is deliberately no unprivileged/testing command-line bypass in the
// production daemon. Isolated tests compile the pure supporting sources instead.
guard CommandLine.arguments.count == 1 else { exit(64) }
do {
    let paths = try ServicePaths.production()
    let service = try AccountProxyService(paths: paths)
    let listener = try createControlSocket(paths, files: service.files)
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { service.monitor() }
    timer.resume()
    var signals: [DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { service.shutdown(); unlink(paths.controlSocket.path); exit(0) }
        source.resume(); signals.append(source)
    }
    while true {
        let peer = accept(listener, nil, nil)
        if peer < 0 { if errno == EINTR { continue }; break }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let response: [String: Any]
        do {
            let uid = try service.authorizedPeer(peer)
            let request = try HelperRequest.decode(readRequest(peer))
            response = ["ok": true, "result": try service.handle(request, uid: uid)]
        } catch let failure as HelperFailure {
            response = ["ok": false, "code": failure.code, "message": failure.message]
        } catch {
            // Avoid logging core diagnostics/configuration/credentials or placing
            // arbitrary filesystem/process descriptions into an IPC error.
            response = ["ok": false, "code": "service_failed", "message": "系统网络服务操作未完成，原有数据已保留。"]
        }
        if var data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
            data.append(10); try? sendAll(data, socket: peer)
        }
        close(peer)
    }
    service.shutdown()
    withExtendedLifetime((timer, signals)) {}
} catch {
    // launchd sees a bounded generic failure exit code; no sensitive details.
    exit(78)
}
