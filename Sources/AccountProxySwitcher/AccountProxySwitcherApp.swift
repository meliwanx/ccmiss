import AppKit
import SwiftUI

@main
struct AccountProxySwitcherApp: App {
    @StateObject private var model = AppModel()

    init() {
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: "compactWindowLayoutVersion") < 3 {
            // Apply the smaller default once on upgrade; later user resizing is retained.
            for key in defaults.dictionaryRepresentation().keys where
                key.contains("AccountProxySwitcher.ContentView") &&
                (key.hasPrefix("NSWindow Frame ") || key.hasPrefix("NSSplitView Subview Frames ")) {
                defaults.removeObject(forKey: key)
            }
            defaults.set(3, forKey: "compactWindowLayoutVersion")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.bootstrap() }
                .preferredColorScheme(nil)
        }
        .defaultSize(width: 740, height: 380)
        .commands {
            CommandGroup(replacing: .help) {
                Button("ccmiss 使用说明") {
                    if let url = Bundle.main.url(forResource: "使用说明", withExtension: "md") { NSWorkspace.shared.open(url) }
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 ccmiss") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "ccmiss", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1", .credits: NSAttributedString(string: "本机多账号 SOCKS5 出口管理\n独立网络服务与 Claude Code 对话维护工具。")])
                }
            }
        }
    }
}
