import Foundation

enum SetupCheckState {
    case pending, ready, actionRequired, unavailable
}

struct EnvironmentSetupCheck: Identifiable {
    let id: String
    let title: String
    let detail: String
    let state: SetupCheckState
}

struct EnvironmentSetupReport {
    let isInitialized: Bool
    let networkReady: Bool
    let hasManagedConfiguration: Bool
    let canInitialize: Bool
    let needsBrowserRestart: Bool
    let requiresManualWebRTC: Bool
    let requiresBrowserFileAccess: Bool
    let hasNetworkConflict: Bool
    let conflictMessage: String
    let message: String
    let checks: [EnvironmentSetupCheck]
}

/// Global network preparation is independent of an active account or browser state.
/// Browser/WebRTC checks remain separate warnings in EnvironmentSetupReport.
enum AppSetupRequirement: Equatable {
    case checking
    case networkPermission
    case approvalPending
    case conflict
    case networkUnavailable
    case ready
}

enum AppSetupNextAction: Equatable {
    case openSoftwareSettings
    case retry
    case retryActivation
    case none
}

struct AppActivationNotice: Equatable {
    let message: String
    let nextAction: AppSetupNextAction
}

enum AccountNetworkAction: Equatable {
    case enable, switchAccount, stop, checkStatus

    var title: String {
        switch self {
        case .enable: return "启用此配置"
        case .switchAccount: return "切换到此配置"
        case .stop: return "停用并恢复系统网络"
        case .checkStatus: return "检查当前状态"
        }
    }

    var symbol: String {
        switch self {
        case .enable: return "power"
        case .switchAccount: return "arrow.triangle.swap"
        case .stop: return "stop.circle"
        case .checkStatus: return "arrow.clockwise"
        }
    }

    static func evaluate(profileID: UUID, activeProfileID: UUID?, modeKnown: Bool,
                         accountMode: Bool, operational: Bool, needsAttention: Bool) -> Self {
        guard modeKnown, !needsAttention else { return .checkStatus }
        guard accountMode else { return .enable }
        guard operational, let activeProfileID else { return .checkStatus }
        return profileID == activeProfileID ? .stop : .switchAccount
    }
}

struct AppSetupReadiness: Equatable {
    let requirement: AppSetupRequirement
    let summary: String
    let nextAction: AppSetupNextAction
    var canActivate: Bool { requirement == .ready }

    static func evaluate(authorization: String, helperAvailable: Bool,
                         hasNetworkConflict: Bool, networkCanInitialize: Bool,
                         checked: Bool, isBusy: Bool) -> AppSetupReadiness {
        func result(_ requirement: AppSetupRequirement, _ summary: String,
                    _ nextAction: AppSetupNextAction) -> AppSetupReadiness {
            AppSetupReadiness(requirement: requirement, summary: summary, nextAction: nextAction)
        }
        guard checked, !isBusy else {
            return result(.checking, "正在检查软件是否已准备好，请稍候。", .none)
        }
        // Resolve authorization before a conflicting proxy: it is the first action
        // the user can complete without changing the current network route.
        if authorization == "notInstalled" {
            return result(.networkPermission, "请先在“软件设置”允许 ccmiss 管理网络。这项授权适用于所有账号。", .openSoftwareSettings)
        }
        if authorization == "requiresApproval" {
            return result(.approvalPending, "macOS 正等待你的确认，请在软件设置中点“打开系统授权”完成允许。", .openSoftwareSettings)
        }
        if hasNetworkConflict {
            return result(.conflict, "其他软件正在管理网络，请在任务结束后退出它，再启用账号。", .openSoftwareSettings)
        }
        guard authorization == "authorized" else {
            return result(.networkUnavailable, "暂时无法确认网络授权，请打开软件设置重新检查。", .openSoftwareSettings)
        }
        guard helperAvailable else {
            return result(.networkUnavailable, "网络功能已授权，但暂未响应，请重新检查。", .retry)
        }
        guard networkCanInitialize else {
            return result(.networkUnavailable, "当前网络暂时不能启用代理，可在软件设置中查看原因。", .openSoftwareSettings)
        }
        return result(.ready, "软件已准备好，可以启用账号。", .none)
    }
}
