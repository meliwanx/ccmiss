import Foundation

@main
struct AppSetupPolicySelfTest {
    static var checks = 0
    static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        guard condition else { fatalError("FAILED: \(label)") }
    }

    static func readiness(_ authorization: String = "authorized", helper: Bool = true,
                          conflict: Bool = false, network: Bool = true,
                          checked: Bool = true, busy: Bool = false) -> AppSetupReadiness {
        AppSetupReadiness.evaluate(authorization: authorization, helperAvailable: helper,
                                  hasNetworkConflict: conflict, networkCanInitialize: network,
                                  checked: checked, isBusy: busy)
    }

    static func main() {
        let ready = readiness()
        expect(ready.requirement == .ready && ready.canActivate && ready.nextAction == .none,
               "prepared idle environment enables activation without any account/runtime/browser inputs")
        expect(readiness(checked: false).requirement == .checking,
               "unchecked inputs never enable activation")
        expect(readiness("notInstalled", conflict: true, busy: true).requirement == .checking,
               "in-flight global preparation waits for its current operation")

        let permission = readiness("notInstalled", helper: false, conflict: true, network: false)
        expect(permission.requirement == .networkPermission && permission.nextAction == .openSoftwareSettings,
               "missing permission is actionable before an existing proxy conflict")
        let pending = readiness("requiresApproval", helper: false, conflict: true, network: false)
        expect(pending.requirement == .approvalPending && pending.nextAction == .openSoftwareSettings,
               "pending macOS approval is actionable before an existing proxy conflict")
        let conflict = readiness(helper: false, conflict: true, network: false)
        expect(conflict.requirement == .conflict && conflict.nextAction == .openSoftwareSettings,
               "authorized environment reports proxy conflict before secondary network failures")
        let disconnectedHelper = readiness(helper: false)
        expect(disconnectedHelper.requirement == .networkUnavailable && disconnectedHelper.nextAction == .retry,
               "unreachable authorized helper offers a safe retry")
        let unavailableNetwork = readiness(network: false)
        expect(unavailableNetwork.requirement == .networkUnavailable && unavailableNetwork.nextAction == .openSoftwareSettings,
               "other missing network conditions direct users to their check results")
        for authorization in ["unknown", "unavailable", "futureAuthorizationState"] {
            let result = readiness(authorization)
            expect(result.requirement == .networkUnavailable && !result.canActivate,
                   "unrecognized or unavailable authorization fails closed")
        }
        for result in [permission, pending, conflict, disconnectedHelper, unavailableNetwork,
                       readiness(checked: false), readiness(busy: true)] {
            expect(!result.canActivate && !result.summary.isEmpty,
                   "every blocking state has a readable reason and cannot activate")
        }
        let notice = AppActivationNotice(message: permission.summary, nextAction: permission.nextAction)
        expect(notice.message == permission.summary && notice.nextAction == .openSoftwareSettings,
               "inline activation notice carries the policy action without presenting UI")
        expect(readiness() == ready, "classification is deterministic and does not persist settings")
        let active = UUID(), other = UUID()
        func action(_ profile: UUID, modeKnown: Bool = true, accountMode: Bool = true,
                    operational: Bool = true, attention: Bool = false, activeID: UUID? = active) -> AccountNetworkAction {
            AccountNetworkAction.evaluate(profileID: profile, activeProfileID: activeID,
                                          modeKnown: modeKnown, accountMode: accountMode,
                                          operational: operational, needsAttention: attention)
        }
        expect(action(active) == .stop, "the confirmed active account stops instead of applying again")
        expect(action(other) == .switchAccount, "selecting another account offers a switch and never stops the active account")
        expect(action(active, accountMode: false, operational: false, activeID: nil) == .enable,
               "confirmed system mode offers enable even with no account core")
        expect(action(active, modeKnown: false) == .checkStatus, "unknown runtime never offers a destructive toggle")
        expect(action(active, attention: true) == .checkStatus, "unconfirmed recovery requires a state check")
        expect(action(active, operational: false) == .checkStatus, "stale active ID is not proof of an active route")
        expect(action(other, activeID: nil) == .checkStatus, "account mode without an owner is not treated as system mode")
        expect(action(active).title == "停用并恢复系统网络", "active account has an explicit restore-system action")
        print("PASS: \(checks) app setup policy checks; synthetic inputs only, no settings/network/UserDefaults access.")
    }
}
