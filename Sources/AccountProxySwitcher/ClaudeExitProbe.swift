import Foundation
import Darwin

/// One new HTTPS request to Claude, through macOS's current networking settings.
/// This is deliberately separate from an account's configured or preflight IP.
struct ClaudeExitObservation: Equatable {
    let ip: String
    let checkedAt: Date
}

enum ClaudeExitProbe {
    static let maximumResponseBytes = 64 * 1024
    private static let endpointHost = "claude.ai"
    private static let endpointPath = "/cdn-cgi/trace"

    enum ProbeError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case unexpectedEndpoint
        case responseTooLarge
        case invalidTrace
        case timeout
        case tls
        case network

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Claude 出口检测未收到有效的 HTTPS 响应。"
            case .httpStatus(let code): return "Claude 出口检测返回 HTTP \(code)，暂时无法确认 IP。"
            case .unexpectedEndpoint: return "Claude 出口检测地址发生变化，未采用本次结果。"
            case .responseTooLarge: return "Claude 出口检测响应过大，未采用本次结果。"
            case .invalidTrace: return "Claude 出口检测没有返回有效 IP。"
            case .timeout: return "Claude 出口检测超时，请稍后重试。"
            case .tls: return "Claude 出口检测的安全连接未通过，请检查当前网络。"
            case .network: return "暂时无法连接 Claude 检测出口，请检查当前网络后重试。"
            }
        }
    }

    static func measure() async throws -> ClaudeExitObservation {
        try Task.checkCancellation()
        // A fresh session has its own connection pool; it cannot reuse a previous
        // probe's connection after the selected account changes. Leave proxy
        // configuration unset so CFNetwork follows the current system proxy/PAC.
        let delegate = RedirectBlocker()
        let session = URLSession(configuration: makeSessionConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler(operation: {
                let (bytes, response) = try await session.bytes(for: makeRequest())
                try validate(response)
                if response.expectedContentLength > Int64(maximumResponseBytes) {
                    throw ProbeError.responseTooLarge
                }
                var body = Data()
                body.reserveCapacity(2048)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < maximumResponseBytes else { throw ProbeError.responseTooLarge }
                    body.append(byte)
                }
                try Task.checkCancellation()
                return try decode(body, response: response)
            }, onCancel: {
                session.invalidateAndCancel()
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProbeError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let failure = error as NSError
            if failure.domain == NSURLErrorDomain {
                if failure.code == NSURLErrorCancelled { throw CancellationError() }
                if failure.code == NSURLErrorTimedOut { throw ProbeError.timeout }
                if [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                    NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                    NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                    NSURLErrorClientCertificateRequired].contains(failure.code) { throw ProbeError.tls }
            }
            // Never surface a response body, URL credentials, proxy details, or
            // an arbitrary third-party error string in the product UI.
            throw ProbeError.network
        }
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func makeRequest() -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpointHost
        components.path = endpointPath
        components.queryItems = [URLQueryItem(name: "ccmiss_probe", value: UUID().uuidString)]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        return request
    }

    static func decode(_ data: Data, response: URLResponse, checkedAt: Date = Date()) throws -> ClaudeExitObservation {
        try validate(response)
        guard data.count <= maximumResponseBytes else { throw ProbeError.responseTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ProbeError.invalidTrace }
        let values = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("ip=") else { return nil }
            return String(line.dropFirst(3))
        }
        // More than one IP field is ambiguous, even if both values are equal.
        guard values.count == 1, let ip = values.first, isIPAddress(ip) else { throw ProbeError.invalidTrace }
        return ClaudeExitObservation(ip: ip, checkedAt: checkedAt)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ProbeError.invalidResponse }
        guard let url = http.url, url.scheme?.lowercased() == "https", url.host?.lowercased() == endpointHost,
              url.path == endpointPath, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { throw ProbeError.unexpectedEndpoint }
        guard http.statusCode == 200 else { throw ProbeError.httpStatus(http.statusCode) }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("%"), !value.contains(where: \.isWhitespace) else { return false }
        var ipv4 = in_addr(), ipv6 = in6_addr()
        return value.withCString { address in
            inet_pton(AF_INET, address, &ipv4) == 1 || inet_pton(AF_INET6, address, &ipv6) == 1
        }
    }

    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
