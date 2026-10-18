import Foundation
import Darwin
import CryptoKit

@main struct HelperSafetySelfTest {
    static var count = 0
    static func expect(_ result: Bool, _ label: String) {
        count += 1
        guard result else { fatalError("FAILED: \(label)") }
    }
    static func rejects(_ label: String, _ action: () throws -> Void) {
        do { try action(); fatalError("FAILED: \(label)") } catch { count += 1 }
    }
    static func main() throws {
        guard geteuid() != 0 else { fatalError("Run these isolated tests unprivileged.") }
        let fm = FileManager.default
        let temporary = URL(fileURLWithPath: "/private/tmp/APSHelperTest-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        func validate(_ object: [String: Any]) throws -> [String: Any] { try HelperConfiguration.validated(object, controllerPath: "/root-private/core.sock", secret: "test-only-secret") }
        for path in CommandLine.arguments.dropFirst(2) {
            let generated = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
            expect(try validate(generated)["mode"] as? String == "rule", "actual standalone-engine generated configuration accepted")
        }
        let trusted = try validate(fixture)
        expect((trusted["tun"] as? [String: Any])?["device"] as? String == "utun1998", "fixed owned tunnel")
        expect(trusted["external-controller"] as? String == "", "no TCP controller")
        expect(trusted["external-controller-unix"] as? String == "/root-private/core.sock", "private controller override")
        expect(trusted["log-level"] as? String == "silent", "no credential diagnostic logging")
        expect(trusted["geo-auto-update"] as? Bool == false, "geodata updates off")
        for key in ["external-controller", "external-controller-unix", "proxy-providers", "rule-providers", "script", "external-ui", "external-ui-url", "geox-url", "listeners", "hosts"] {
            var bad = fixture; bad[key] = "/tmp/user-controlled"
            rejects("reject dangerous top key \(key)") { _ = try validate(bad) }
        }
        var changed = fixture
        changed["mixed-port"] = 8080
        rejects("no privileged public listener") { _ = try validate(changed) }
        changed = fixture
        var tun = changed["tun"] as! [String: Any]; tun["enable"] = false; changed["tun"] = tun
        rejects("production tunnel cannot be disabled") { _ = try validate(changed) }
        changed = fixture
        var proxy = (changed["proxies"] as! [[String: Any]])[0]; proxy["type"] = "ss"; changed["proxies"] = [proxy]
        rejects("only SOCKS5 inline proxy") { _ = try validate(changed) }
        changed = fixture; proxy = (changed["proxies"] as! [[String: Any]])[0]; proxy["server"] = "/tmp/file"; changed["proxies"] = [proxy]
        rejects("no path host") { _ = try validate(changed) }
        changed = fixture; proxy = (changed["proxies"] as! [[String: Any]])[0]; proxy["dialer-proxy"] = "arbitrary"; changed["proxies"] = [proxy]
        rejects("no unvalidated upstream") { _ = try validate(changed) }
        changed = fixture
        var dns = changed["dns"] as! [String: Any]; dns["nameserver"] = ["file:///tmp/config"]; changed["dns"] = dns
        rejects("resolver cannot load a local path") { _ = try validate(changed) }
        changed = fixture; dns = changed["dns"] as! [String: Any]; dns["fallback-filter"] = ["geoip": true]; changed["dns"] = dns
        rejects("no implicit geodata download") { _ = try validate(changed) }
        changed = fixture; dns = changed["dns"] as! [String: Any]; dns["nameserver-policy"] = ["+.example.internal": ["10.2.3.4#DIRECT"]]; changed["dns"] = dns
        expect(try validate(changed)["dns"] != nil, "private DNS DIRECT exception allowed")
        changed = fixture; dns = changed["dns"] as! [String: Any]; dns["nameserver-policy"] = ["+.example.internal": ["8.8.8.8#DIRECT"]]; changed["dns"] = dns
        rejects("public plain DNS direct exception rejected") { _ = try validate(changed) }
        changed = fixture; changed["rules"] = ["PROCESS-NAME,WeChat,DIRECT", "PROCESS-PATH,/Applications/Example.app/Contents/MacOS/Example,DIRECT", "MATCH,DIRECT"]
        expect(try validate(changed)["rules"] != nil, "process matching DIRECT does not execute paths")
        changed["rules"] = ["PROCESS-PATH,/tmp/test,Account Proxy Exit", "MATCH,DIRECT"]
        rejects("process rules cannot introduce arbitrary routing") { _ = try validate(changed) }
        for rule in ["RULE-SET,/tmp/a,DIRECT", "SCRIPT,/tmp/a,DIRECT", "GEOSITE,private,DIRECT", "IP-CIDR,127.0.0.1/32,UNDEFINED,no-resolve"] {
            changed = fixture; changed["rules"] = [rule]
            rejects("reject unsafe rule") { _ = try validate(changed) }
        }
        var primary = (fixture["proxies"] as! [[String: Any]])[0]
        primary["dialer-proxy"] = "Account Proxy Upstream"
        let realityFront: [String: Any] = ["name":"Account Proxy Upstream", "type":"vless", "server":"192.0.2.20", "port":443,
            "uuid":"00000000-0000-4000-8000-000000000002", "flow":"xtls-rprx-vision", "encryption":"none", "tls":true,
            "skip-cert-verify":false, "servername":"example.com", "client-fingerprint":"chrome", "network":"tcp", "udp":false,
            "reality-opts":["public-key":String(repeating:"A",count:43), "short-id":"0123456789abcdef"]]
        var chained = fixture; chained["proxies"] = [realityFront, primary]
        expect(try validate(chained)["proxies"] != nil, "Reality front with one SOCKS final exit accepted")
        let socksFront: [String: Any] = ["name":"Account Proxy Upstream", "type":"socks5", "server":"192.0.2.30", "port":1080,"udp":false,"username":"fake","password":"test-only"]
        chained["proxies"] = [primary,socksFront]
        expect(try validate(chained)["proxies"] != nil, "inline SOCKS front accepted")
        for (key, value): (String, Any) in [("tls",false),("skip-cert-verify",true),("network","ws"),("flow","unexpected"),("uuid","bad"),("encryption","aes"),("script","/tmp/exec"),("dialer-proxy","another"),("udp",true)] {
            var badFront = realityFront; badFront[key] = value
            chained["proxies"] = [primary,badFront]
            rejects("unsafe Reality front rejected") { _ = try validate(chained) }
        }
        for reality in [["public-key":"bad", "short-id":""], ["public-key":String(repeating:"A",count:43), "short-id":"abc"], ["public-key":String(repeating:"A",count:43), "short-id":"zz"]] {
            var badFront = realityFront; badFront["reality-opts"] = reality
            chained["proxies"] = [primary,badFront]
            rejects("invalid Reality key/short id rejected") { _ = try validate(chained) }
        }
        chained["proxies"] = [primary,realityFront,socksFront]
        rejects("no third proxy or fallback") { _ = try validate(chained) }
        chained["proxies"] = [primary]
        rejects("dangling dialer rejected") { _ = try validate(chained) }
        var extraDialer = socksFront; extraDialer["dialer-proxy"] = "Account Proxy Active"
        chained["proxies"] = [primary,extraDialer]
        rejects("recursive front dialer rejected") { _ = try validate(chained) }
        let uuid = UUID().uuidString
        let validRequest = try JSONSerialization.data(withJSONObject: ["version":1,"command":"apply","configuration":fixture,"generation":uuid])
        expect(try HelperRequest.decode(validRequest).generation == uuid, "framed apply schema")
        for object: [String: Any] in [["version":2,"command":"status"], ["version":1,"command":"exec"], ["version":1,"command":"query","endpoint":"/configs"], ["version":1,"command":"apply","configuration":fixture,"generation":"not-uuid"], ["version":1,"command":"status","path":"/etc/passwd"]] {
            rejects("invalid request denied") { _ = try HelperRequest.decode(JSONSerialization.data(withJSONObject: object)) }
        }
        rejects("bounded request") { _ = try HelperRequest.decode(Data(repeating: 32, count: HelperRequest.maximumBytes + 1)) }
        let helper = URL(fileURLWithPath: "/Applications/账号出口切换器.app/Contents/Library/HelperTools/AccountProxyService")
        expect(try ServicePaths.bundleRoot(helperExecutable: helper).path == "/Applications/账号出口切换器.app", "correct four-level bundle root")
        rejects("helper outside Applications refused") { _ = try ServicePaths.bundleRoot(helperExecutable: URL(fileURLWithPath: "/tmp/Test.app/Contents/Library/HelperTools/AccountProxyService")) }
        rejects("unrecognized bundle executable refused") { _ = try ServicePaths.bundleRoot(helperExecutable: URL(fileURLWithPath: "/Applications/Test.app/Contents/MacOS/AccountProxyService")) }

        let files = SecureServiceFiles(owner: getuid())
        let runtime = temporary.appendingPathComponent("runtime")
        try files.directory(runtime)
        let file = runtime.appendingPathComponent("secret.json"), original = Data("test-only".utf8)
        try files.write(original, to: file)
        expect(try files.read(file) == original, "atomic bytes preserved")
        expect((try fm.attributesOfItem(atPath: runtime.path)[.posixPermissions] as! NSNumber).intValue == 0o700, "runtime mode 0700")
        expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue == 0o600, "configuration mode 0600")
        let source = temporary.appendingPathComponent("bundled-core")
        let executable = Data("unit test core bytes; never executable".utf8)
        try executable.write(to: source)
        let digest = SHA256.hash(data: executable).map { String(format:"%02x",$0) }.joined()
        let staged = runtime.appendingPathComponent("core")
        try files.stageCore(from: source, to: staged, expectedHash: digest)
        expect(try files.read(staged) == executable, "verified core safely staged")
        expect((try fm.attributesOfItem(atPath: staged.path)[.posixPermissions] as! NSNumber).intValue == 0o700, "core executable owner-only")
        rejects("core digest pin enforced") { try files.stageCore(from: source, to: staged, expectedHash: String(repeating:"0",count:64)) }
        expect(try files.read(staged) == executable, "invalid digest cannot replace staged core")
        let sourceLink = temporary.appendingPathComponent("core-link")
        try fm.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        rejects("source symlink rejected") { try files.stageCore(from: sourceLink, to: staged, expectedHash: digest) }
        let targetLink = runtime.appendingPathComponent("target-link")
        try fm.createSymbolicLink(at: targetLink, withDestinationURL: file)
        rejects("destination symlink rejected") { try files.write(Data(), to: targetLink) }
        expect(try files.read(file) == original, "symlink attack preserves target")

        expect(DNSRestoration.restore(current:["ServerAddresses":["127.0.0.1"]],original:nil) == nil, "DHCP DNS restored by removing owned override")
        let restored = DNSRestoration.restore(current:["ServerAddresses":["127.0.0.1"],"SearchDomains":["new.local"]],original:["ServerAddresses":["10.0.0.1"],"SearchDomains":["old.local"]])!
        expect(restored["ServerAddresses"] as? [String] == ["10.0.0.1"], "manual DNS restored")
        expect(restored["SearchDomains"] as? [String] == ["new.local"], "unrelated external DNS changes preserved")
        let external = DNSRestoration.restore(current:["ServerAddresses":["9.9.9.9"]],original:["ServerAddresses":["10.0.0.1"]])!
        expect(external["ServerAddresses"] as? [String] == ["9.9.9.9"], "external resolver ownership respected")
        expect(DNSOwnershipAction.plan(current: ["ServerAddresses": ["127.0.0.1"]], wasCaptured: true) == .unchanged, "healthy DNS monitoring avoids write/commit")
        expect(DNSOwnershipAction.plan(current: ["ServerAddresses": ["9.9.9.9"]], wasCaptured: true) == .externalChange, "external DNS change stops ownership")
        expect(DNSOwnershipAction.plan(current: nil, wasCaptured: true) == .externalChange, "external removal is also ownership change")
        expect(DNSOwnershipAction.plan(current: ["ServerAddresses": ["10.0.0.1"]], wasCaptured: false) == .takeover, "new service captured before takeover")
        expect(DNSOwnershipAction.plan(current: ["ServerAddresses": ["127.0.0.1"]], wasCaptured: false) == .unchanged, "existing matching DNS causes no unnecessary commit")
        expect(ServiceOwnerSessionDecision.decide(ownerUID: 501, consoleUID: 502, running: true, activeIntent: true) == .pause, "another console user pauses owned network")
        expect(ServiceOwnerSessionDecision.decide(ownerUID: 501, consoleUID: nil, running: true, activeIntent: true) == .pause, "loginwindow pauses owned network")
        expect(ServiceOwnerSessionDecision.decide(ownerUID: 501, consoleUID: 501, running: false, activeIntent: true) == .resume, "owner returns with preserved activation intent")
        expect(ServiceOwnerSessionDecision.decide(ownerUID: 501, consoleUID: 501, running: false, activeIntent: false) == .unchanged, "never auto-start before successful apply")
        expect(ServiceOwnerSessionDecision.decide(ownerUID: 501, consoleUID: 501, running: true, activeIntent: true) == .unchanged, "normal owner session is untouched")
        expect(!DNSRestorationStatus.isPending(hasBackup: true, running: true, activeIntent: true, ownerUID: 501, consoleUID: 501), "normal active DNS snapshot is not restoration pending")
        expect(DNSRestorationStatus.isPending(hasBackup: true, running: false, activeIntent: false, ownerUID: 501, consoleUID: 501), "idle DNS backup requires restoration confirmation")
        expect(DNSRestorationStatus.isPending(hasBackup: true, running: true, activeIntent: false, ownerUID: 501, consoleUID: 501), "failed stop retains resolver until DNS is restored")
        expect(DNSRestorationStatus.isPending(hasBackup: true, running: true, activeIntent: true, ownerUID: 501, consoleUID: 502), "console transition pending DNS is explicit")
        expect(!DNSRestorationStatus.isPending(hasBackup: false, running: false, activeIntent: false, ownerUID: nil, consoleUID: 501), "no stale snapshot means no DNS restore pending")
        let appPath = "/Applications/账号出口切换器.app"
        let mainPath = appPath + "/Contents/MacOS/AccountProxySwitcher"
        let nodePath = appPath + "/Contents/Resources/node"
        expect(HelperPeerOriginPolicy.isAllowed(clientPath: mainPath, parentPath: "/sbin/launchd", applicationPath: appPath, parentSignatureValid: false), "signed main app can connect directly")
        expect(HelperPeerOriginPolicy.isAllowed(clientPath: nodePath, parentPath: mainPath, applicationPath: appPath, parentSignatureValid: true), "bundled node requires signed main parent")
        expect(!HelperPeerOriginPolicy.isAllowed(clientPath: nodePath, parentPath: "/bin/zsh", applicationPath: appPath, parentSignatureValid: true), "terminal launched bundled interpreter denied")
        expect(!HelperPeerOriginPolicy.isAllowed(clientPath: nodePath, parentPath: mainPath, applicationPath: appPath, parentSignatureValid: false), "unsigned or wrong Team parent denied")
        expect(!HelperPeerOriginPolicy.isAllowed(clientPath: nodePath, parentPath: nil, applicationPath: appPath, parentSignatureValid: true), "orphaned interpreter denied")
        expect(!HelperPeerOriginPolicy.isAllowed(clientPath: "/usr/local/bin/node", parentPath: mainPath, applicationPath: appPath, parentSignatureValid: true), "external interpreter denied")
        expect(!HelperPeerOriginPolicy.isAllowed(clientPath: nodePath, parentPath: "/Applications/Other.app/Contents/MacOS/AccountProxySwitcher", applicationPath: appPath, parentSignatureValid: true), "different installed app parent denied")
        print("Helper isolated safety checks passed: \(count). No daemon, TUN, DNS mutation, registration or privileged execution performed.")
    }
}
