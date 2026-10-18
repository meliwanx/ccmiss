import AppKit
import Foundation
import ServiceManagement

enum BackgroundServiceAuthorizationState: String {
    case unknown, notInstalled, requiresApproval, authorized, unavailable
}

@MainActor
enum StandaloneBackgroundService {
    static let label = "io.ccmiss.app.network-service"

    static var authorizationState: BackgroundServiceAuthorizationState {
        state(for: SMAppService.daemon(plistName: label + ".plist").status,
              bundledServiceAvailable: hasBundledService())
    }

    static func state(for status: SMAppService.Status, bundledServiceAvailable: Bool) -> BackgroundServiceAuthorizationState {
        switch status {
        case .notRegistered: return .notInstalled
        case .enabled: return .authorized
        case .requiresApproval: return .requiresApproval
        case .notFound: return bundledServiceAvailable ? .notInstalled : .unavailable
        @unknown default: return .unknown
        }
    }

    private static func hasBundledService() -> Bool {
        let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Library", isDirectory: true)
        let plist = library.appendingPathComponent("LaunchDaemons/" + label + ".plist")
        let helper = library.appendingPathComponent("HelperTools/AccountProxyService")
        let manager = FileManager.default
        guard let plistAttributes = try? manager.attributesOfItem(atPath: plist.path),
              plistAttributes[.type] as? FileAttributeType == .typeRegular,
              let helperAttributes = try? manager.attributesOfItem(atPath: helper.path),
              helperAttributes[.type] as? FileAttributeType == .typeRegular,
              manager.isExecutableFile(atPath: helper.path) else { return false }
        return true
    }

    static func register() throws {
        // Registration only starts the idle control service. It cannot enable
        // TUN or change DNS until a separate explicit initialize request.
        try SMAppService.daemon(plistName: label + ".plist").register()
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
