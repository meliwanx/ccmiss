import Foundation

/// Pure fixtures only: this executable never opens a network connection.
@main
struct ClaudeExitProbeSelfTest {
    static var checks = 0

    static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        guard condition else { fatalError("FAILED: \(label)") }
    }

    static func mustThrow(_ label: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAILED: \(label)") }
        catch { checks += 1 }
    }

    static func response(_ url: String = "https://claude.ai/cdn-cgi/trace?ccmiss_probe=fixture", status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
    }

    static func main() async throws {
        let timestamp = Date(timeIntervalSince1970: 12345)
        let ipv4 = try ClaudeExitProbe.decode(Data("fl=abc\nip=192.0.2.10\nloc=US\n".utf8), response: response(), checkedAt: timestamp)
        expect(ipv4.ip == "192.0.2.10" && ipv4.checkedAt == timestamp, "trace IP and observation time are carried together")
        let ipv6 = try ClaudeExitProbe.decode(Data("ip=2001:db8::1234\r\nloc=US\r\n".utf8), response: response())
        expect(ipv6.ip == "2001:db8::1234", "IPv6 and CRLF traces are accepted")
        for value in ["", "192.0.2.999", "198.51.100.10:1080", "[2001:db8::1]", "fe80::1%en0", "192.0.2.4 ", " 192.0.2.4", "localhost", "127.1", "192.0.2.4<script>"] {
            mustThrow("invalid trace IP rejected: \(value)") {
                _ = try ClaudeExitProbe.decode(Data("ip=\(value)\n".utf8), response: response())
            }
        }
        for body in ["", "<html>192.0.2.4</html>", "ip=192.0.2.4\nip=192.0.2.4\n", "ip=192.0.2.4\nip=198.51.100.8\n", " xip=192.0.2.4\n"] {
            mustThrow("missing or ambiguous field is rejected") {
                _ = try ClaudeExitProbe.decode(Data(body.utf8), response: response())
            }
        }
        mustThrow("invalid UTF-8 rejected") { _ = try ClaudeExitProbe.decode(Data([0xff, 0xfe]), response: response()) }
        for status in [201, 204, 301, 302, 403, 429, 500] {
            mustThrow("HTTP \(status) never becomes an observed IP") {
                _ = try ClaudeExitProbe.decode(Data("ip=192.0.2.4\n".utf8), response: response(status: status))
            }
        }
        for url in ["http://claude.ai/cdn-cgi/trace", "https://example.com/cdn-cgi/trace", "https://claude.ai.example.com/cdn-cgi/trace", "https://claude.ai/login", "https://" + "user:password@" + "claude.ai/cdn-cgi/trace", "https://claude.ai:8443/cdn-cgi/trace"] {
            mustThrow("unexpected response endpoint rejected") {
                _ = try ClaudeExitProbe.decode(Data("ip=192.0.2.4\n".utf8), response: response(url))
            }
        }
        mustThrow("non-HTTP response rejected") {
            let plain = URLResponse(url: URL(string: "https://claude.ai/cdn-cgi/trace")!, mimeType: "text/plain", expectedContentLength: 12, textEncodingName: "utf8")
            _ = try ClaudeExitProbe.decode(Data("ip=192.0.2.4\n".utf8), response: plain)
        }
        var maximum = Data("ip=192.0.2.4\nother=".utf8)
        maximum.append(Data(repeating: 65, count: ClaudeExitProbe.maximumResponseBytes - maximum.count))
        expect(try ClaudeExitProbe.decode(maximum, response: response()).ip == "192.0.2.4", "response limit is inclusive")
        maximum.append(65)
        mustThrow("response above 64 KiB rejected") { _ = try ClaudeExitProbe.decode(maximum, response: response()) }

        let configuration = ClaudeExitProbe.makeSessionConfiguration()
        expect(configuration.connectionProxyDictionary == nil, "macOS default proxy/PAC settings are preserved")
        expect(configuration.urlCache == nil && configuration.requestCachePolicy == .reloadIgnoringLocalCacheData, "no cache is consulted or persisted")
        expect(!configuration.httpShouldSetCookies && configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil, "no account cookies or stored credentials are reused")
        expect(configuration.timeoutIntervalForRequest == 12 && configuration.timeoutIntervalForResource == 15 && !configuration.waitsForConnectivity, "probe latency is bounded")
        let first = ClaudeExitProbe.makeRequest(), second = ClaudeExitProbe.makeRequest()
        expect(first.url != second.url, "each probe uses a fresh cachebuster")
        expect(first.url?.scheme == "https" && first.url?.host == "claude.ai" && first.url?.path == "/cdn-cgi/trace", "probe always targets the fixed official HTTPS trace")
        expect(first.httpMethod == "GET" && first.httpBody == nil && !first.httpShouldHandleCookies, "probe is a read-only request without account data")
        expect(first.value(forHTTPHeaderField: "Cache-Control") == "no-cache, no-store" && first.value(forHTTPHeaderField: "Pragma") == "no-cache", "intermediary caches are discouraged")
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await ClaudeExitProbe.measure(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancelledBeforeNetworking = await cancelled.value
        expect(cancelledBeforeNetworking, "pre-cancelled probe exits before creating a network session")
        print("Claude exit probe offline checks passed: \(checks)")
    }
}
