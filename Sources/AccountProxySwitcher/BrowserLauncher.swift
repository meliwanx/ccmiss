import AppKit
import Foundation

enum BrowserCheck: String, CaseIterable, Identifiable {
    case claude, cloudflare, dns, webrtc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .cloudflare: return "Cloudflare"
        case .dns: return "DNS"
        case .webrtc: return "WebRTC"
        }
    }

    var url: URL {
        switch self {
        case .claude: return URL(string: "https://ip.net.coffee/claude/")!
        case .cloudflare: return URL(string: "https://ip.net.coffee/cloudflare/")!
        case .dns: return URL(string: "https://ip.net.coffee/dns/")!
        case .webrtc: return URL(string: "https://ip.net.coffee/webrtc/")!
        }
    }
}

struct BrowserApplication: Equatable {
    let bundleIdentifier: String
    let name: String
    let executableURL: URL
}

struct PrivateBrowserLaunchPlan: Equatable {
    let browserName: String
    let executableURL: URL
    let arguments: [String]
}

enum BrowserLaunchError: LocalizedError {
    case noDefaultBrowser
    case unavailableBrowser
    case unsupportedBrowser(String)
    case invalidURL
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDefaultBrowser: return "未找到默认浏览器，请先在系统设置中选择。"
        case .unavailableBrowser: return "无法读取默认浏览器，请检查浏览器安装。"
        case .unsupportedBrowser(let name): return "\(name) 暂不支持自动无痕打开，请手动开启私密窗口。"
        case .invalidURL: return "检测链接必须是有效的 HTTPS 地址。"
        case .launchFailed(let name): return "无法启动 \(name)，请检查浏览器安装。"
        }
    }
}

/// Pure planning: callers can validate browser support and arguments without
/// launching a process, opening a URL or reading application/profile data.
enum BrowserLaunchPlanner {
    static func plan(browser: BrowserApplication, url: URL) throws -> PrivateBrowserLaunchPlan {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, browser.executableURL.isFileURL else {
            throw BrowserLaunchError.invalidURL
        }
        let identifier = browser.bundleIdentifier.lowercased()
        let incognitoBrowsers: Set<String> = [
            "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev", "com.google.chrome.canary",
            "org.chromium.chromium", "com.brave.browser", "com.brave.browser.beta", "com.brave.browser.nightly"
        ]
        let edgeBrowsers: Set<String> = [
            "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.dev", "com.microsoft.edgemac.canary"
        ]
        let firefoxBrowsers: Set<String> = [
            "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"
        ]
        let arguments: [String]
        if incognitoBrowsers.contains(identifier) {
            // Chromium/Brave use --incognito; launch the executable directly so
            // an existing ordinary window cannot swallow LaunchServices arguments.
            arguments = ["--incognito", "--new-window", url.absoluteString]
        } else if edgeBrowsers.contains(identifier) {
            arguments = ["--inprivate", "--new-window", url.absoluteString]
        } else if firefoxBrowsers.contains(identifier) {
            arguments = ["-private-window", url.absoluteString]
        } else {
            // Safari has no reliable public command-line private-window API.
            // Never fall back to NSWorkspace.open, which could use an ordinary window.
            throw BrowserLaunchError.unsupportedBrowser(browser.name)
        }
        return PrivateBrowserLaunchPlan(browserName: browser.name, executableURL: browser.executableURL, arguments: arguments)
    }
}

@MainActor
enum BrowserLauncher {
    static func defaultBrowser(for url: URL = BrowserCheck.claude.url) throws -> BrowserApplication {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            throw BrowserLaunchError.noDefaultBrowser
        }
        guard let bundle = Bundle(url: applicationURL), let identifier = bundle.bundleIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BrowserLaunchError.unavailableBrowser
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? applicationURL.deletingPathExtension().lastPathComponent
        return BrowserApplication(bundleIdentifier: identifier, name: name, executableURL: executable)
    }

    @discardableResult
    static func openPrivate(_ url: URL) throws -> String {
        // Resolve again for each click, honoring a default-browser change while
        // the utility remains open. No account credentials or proxy settings are read.
        let browser = try defaultBrowser(for: url)
        let plan = try BrowserLaunchPlanner.plan(browser: browser, url: url)
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw BrowserLaunchError.launchFailed(browser.name) }
        return browser.name
    }
}
