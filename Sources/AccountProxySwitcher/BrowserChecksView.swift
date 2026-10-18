import AppKit
import SwiftUI

struct BrowserChecksView: View {
    @ObservedObject var model: AppModel
    @State private var browserName = "默认浏览器"
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Label("无痕检查", systemImage: "safari")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("使用默认浏览器 \(browserName) 的无痕窗口检查网络出口")
                ForEach(BrowserCheck.allCases) { check in
                    Button(check.title) { open(check) }
                        .font(.system(size: 11, weight: .medium))
                        .help("使用默认浏览器 \(browserName) 的无痕窗口打开 \(check.url.absoluteString)")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isBusy)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("privateBrowserError")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { refreshBrowserName() }
    }

    private func refreshBrowserName() {
        do { browserName = try BrowserLauncher.defaultBrowser().name }
        catch { errorMessage = error.localizedDescription }
    }

    private func open(_ check: BrowserCheck) {
        errorMessage = nil
        do { browserName = try BrowserLauncher.openPrivate(check.url) }
        catch {
            if let browser = try? BrowserLauncher.defaultBrowser(for: check.url) { browserName = browser.name }
            errorMessage = error.localizedDescription
        }
    }
}
