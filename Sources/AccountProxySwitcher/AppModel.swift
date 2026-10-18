import AppKit
import Foundation
import SwiftUI

enum AppOperationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [ProxyProfile] = []
    @Published var selectedProfileID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: "selectedProfileID")
            if selectedProfileID != oldValue && !isBusy {
                activationNotice = nil
                activationPreconditionBlocked = false
            }
        }
    }
    @Published var activeProfileID: UUID?
    @Published private(set) var proxyMode: ProxyMode = .system
    @Published private(set) var networkBackend = "standalone"
    @Published private(set) var isProxyModeKnown = false
    @Published private(set) var proxyModeNeedsAttention = false
    @Published private(set) var activationNotice: AppActivationNotice?
    @Published private(set) var browserProtectionStatus: BrowserEnvironmentStatus?
    @Published private(set) var applicationPreparationDiagnostic: String?
    @Published var statusMessage = "正在读取账号与软件设置…"
    @Published var isBusy = false
    @Published private(set) var lastVerification: ExitVerification?
    @Published private(set) var claudeExitObservation: ClaudeExitObservation?
    @Published private(set) var claudeExitError: String?
    @Published private(set) var isCheckingClaudeExit = false
    @Published var engineStatus = EngineStatus()
    @Published var setupReport: EnvironmentSetupReport?
    @Published var isCheckingEnvironment = false
    @Published var serviceAuthorizationState = BackgroundServiceAuthorizationState.unknown
    @Published var upstreamProxySummary = "不使用前置"
    @Published var routingScope: RoutingScope = .servicesOnly {
        didSet { UserDefaults.standard.set(routingScope.rawValue, forKey: "routingScope") }
    }

    private let store = ProfileStore()
    private let engine = StandaloneEngine()
    private var bootstrapped = false
    private var appliedScope: RoutingScope?
    private var networkHelperAvailable = false
    private var networkCanInitialize = false
    private var hasCheckedApplicationEnvironment = false
    private var activationPreconditionBlocked = false
    private var visibleWindowCount = 0
    private var statusMonitorTask: Task<Void, Never>?
    private var networkOperationRevision: UInt64 = 0 {
        didSet { invalidateClaudeExit() }
    }
    private var verificationProfileID: UUID?
    private var reportedExitIP: String?
    private var claudeExitTask: Task<Void, Never>?
    private var claudeExitRequestID: UUID?
    private var claudeExitLastAttempt: Date?
    var claudeExitMatchesAccount: Bool {
        guard isProxyModeKnown, proxyMode == .profile, !proxyModeNeedsAttention,
              engineStatus.isOperational, let expected = reportedExitIP,
              let observation = claudeExitObservation else { return false }
        return expected == observation.ip
    }

    var claudeExitMismatch: Bool {
        guard isProxyModeKnown, proxyMode == .profile, !proxyModeNeedsAttention,
              let expected = reportedExitIP, let observation = claudeExitObservation else { return false }
        return expected != observation.ip
    }

    /// Measure the default macOS path, independently of account preflight checks.
    /// A selected sidebar row has no bearing on the observation's identity.
    func refreshClaudeExit(force: Bool = true) {
        guard bootstrapped, !isBusy, !isCheckingEnvironment else { return }
        if !force {
            guard claudeExitTask == nil,
                  claudeExitLastAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        }
        invalidateClaudeExit()
        let requestID = UUID()
        let revision = networkOperationRevision
        let mode = proxyMode
        let profileID = activeProfileID
        let modeKnown = isProxyModeKnown
        claudeExitRequestID = requestID
        claudeExitLastAttempt = Date()
        isCheckingClaudeExit = true
        claudeExitTask = Task { [weak self] in
            let outcome: Result<ClaudeExitObservation, Error>
            do { outcome = .success(try await ClaudeExitProbe.measure()) }
            catch { outcome = .failure(error) }
            guard let self, !Task.isCancelled,
                  self.claudeExitRequestID == requestID,
                  self.networkOperationRevision == revision,
                  self.proxyMode == mode, self.activeProfileID == profileID,
                  self.isProxyModeKnown == modeKnown else { return }
            switch outcome {
            case .success(let observation): self.claudeExitObservation = observation
            case .failure(let error): self.claudeExitError = error.localizedDescription
            }
            self.isCheckingClaudeExit = false
            self.claudeExitTask = nil
        }
    }

    private func invalidateClaudeExit() {
        claudeExitRequestID = nil
        claudeExitTask?.cancel()
        claudeExitTask = nil
        claudeExitObservation = nil
        claudeExitError = nil
        claudeExitLastAttempt = nil
        isCheckingClaudeExit = false
    }

    private func finishNetworkOperation() {
        isBusy = false
        refreshClaudeExit()
    }

    init() {
        let defaults = UserDefaults.standard
        let preferenceVersionKey = "routingScopePreferenceVersion"
        if defaults.integer(forKey: preferenceVersionKey) < 2 {
            // Migrate only the next-application preference, never the live network.
            if defaults.string(forKey: "routingScope") == RoutingScope.fullPublic.rawValue {
                defaults.set(RoutingScope.servicesOnly.rawValue, forKey: "routingScope")
            }
            defaults.set(2, forKey: preferenceVersionKey)
        }
        routingScope = RoutingScope(rawValue: defaults.string(forKey: "routingScope") ?? "") ?? .servicesOnly
        selectedProfileID = defaults.string(forKey: "selectedProfileID").flatMap(UUID.init(uuidString:))
    }

    var canActivateSelectedConfiguration: Bool {
        profiles.contains(where: { $0.id == selectedProfileID }) && activationReadiness.canActivate
    }

    var applicationPrepared: Bool {
        hasCheckedApplicationEnvironment && networkHelperAvailable &&
            (usesClashCoexist || serviceAuthorizationState == .authorized)
    }

    var usesClashCoexist: Bool { networkBackend == "clashCoexist" }

    func accountNetworkAction(for profile: ProxyProfile) -> AccountNetworkAction {
        AccountNetworkAction.evaluate(profileID: profile.id, activeProfileID: activeProfileID,
                                      modeKnown: isProxyModeKnown, accountMode: proxyMode == .profile,
                                      operational: engineStatus.isOperational, needsAttention: proxyModeNeedsAttention)
    }

    func performAccountNetworkAction(_ profile: ProxyProfile) async {
        guard !isBusy, !isCheckingEnvironment, profiles.contains(where: { $0.id == profile.id }) else { return }
        // Resolve again at click time; sidebar selection never determines what is active.
        switch accountNetworkAction(for: profile) {
        case .stop: await followSystemProxy()
        case .enable, .switchAccount: await activateProfile(profile)
        case .checkStatus: await refreshStatus()
        }
    }

    /// Verification is evidence for one applied account, never for the sidebar selection.
    var currentVerification: ExitVerification? {
        guard isProxyModeKnown, proxyMode == .profile, !proxyModeNeedsAttention,
              engineStatus.isOperational, let activeProfileID,
              verificationProfileID == activeProfileID, let verification = lastVerification else { return nil }
        if verification.success, let reportedExitIP, reportedExitIP != verification.ip { return nil }
        return verification
    }

    var activationReadiness: AppSetupReadiness {
        readiness(isBusy: isBusy || isCheckingEnvironment)
    }

    private func readiness(isBusy: Bool) -> AppSetupReadiness {
        if usesClashCoexist, hasCheckedApplicationEnvironment, !isBusy,
           !networkHelperAvailable || !networkCanInitialize {
            return AppSetupReadiness(requirement: .networkUnavailable,
                                     summary: "暂时无法启用 Clash 共存，请在软件设置中查看检查结果。",
                                     nextAction: .openSoftwareSettings)
        }
        return AppSetupReadiness.evaluate(authorization: usesClashCoexist ? "authorized" : serviceAuthorizationState.rawValue,
                                  helperAvailable: networkHelperAvailable,
                                  hasNetworkConflict: setupReport?.hasNetworkConflict == true,
                                  networkCanInitialize: networkCanInitialize,
                                  checked: hasCheckedApplicationEnvironment, isBusy: isBusy)
    }

    var browserProtectionReady: Bool { browserProtectionStatus?.isReady == true }

    var networkConflictSummary: String? {
        guard setupReport?.hasNetworkConflict == true else { return nil }
        let source = setupReport?.conflictMessage.lowercased() ?? ""
        let name = source.contains("clash") || source.contains("verge") ? "Clash" : "其他代理软件"
        return "当前 \(name) 正在代理。可以先完成授权；等现有任务结束后退出它，再回主界面启用账号。"
    }

    var browserProtectionSummary: String {
        guard let browser = browserProtectionStatus else { return "尚未检查浏览器保护。" }
        if browser.isReady { return "\(browser.browserName) 的现有浏览器配置已设置保护。" }
        if browser.requiresFileAccess { return "尚未设置：需要你在系统设置中允许访问浏览器配置。" }
        if browser.restartRequired { return "尚未设置：请先退出 \(browser.browserName)，再点设置。" }
        if browser.state == .unsupported { return "当前浏览器需要手动设置；不影响账号代理启用。" }
        return "浏览器防泄露尚未设置，可单独处理。"
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        isBusy = true
        defer { finishNetworkOperation() }
        do {
            profiles = try store.loadProfiles()
            let status = try await engine.request("status", payload: [:])
            applyStatus(status)
            if profiles.isEmpty {
                do {
                    let imported = try await engine.request("importCurrent", payload: [:])
                    if let uri = imported["uri"] as? String {
                        try persistNewProfile(name: "当前专用出口", accountDescription: "当前已配置的代理，请填写对应账号", uri: uri)
                        statusMessage = "已读取本应用的专用代理。选择账号后点击切换，才会应用所选范围。"
                    }
                } catch {
                    statusMessage = "可以先添加账号配置。" + error.localizedDescription
                }
            } else {
                statusMessage = status["message"] as? String ?? "配置已加载。选择账号并点击切换。"
            }
            if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = profiles.first?.id
            }
        } catch {
            isProxyModeKnown = false
            proxyModeNeedsAttention = true
            statusMessage = error.localizedDescription
        }
        await updateEnvironmentReport()
    }

    func checkEnvironment() async {
        guard !isBusy, !isCheckingEnvironment else { return }
        await updateEnvironmentReport()
    }

    private func updateEnvironmentReport(inspectBrowser: Bool = true) async {
        isCheckingEnvironment = true
        defer {
            isCheckingEnvironment = false
            if activationPreconditionBlocked {
                let latest = readiness(isBusy: false)
                if latest.canActivate {
                    activationNotice = nil
                    activationPreconditionBlocked = false
                } else {
                    activationNotice = notice(for: latest)
                }
            }
        }
        serviceAuthorizationState = StandaloneBackgroundService.authorizationState
        let browser = inspectBrowser || browserProtectionStatus == nil ? BrowserEnvironmentService.inspect() : browserProtectionStatus!
        browserProtectionStatus = browser
        do {
            let network = try await engine.request("setupStatus")
            networkBackend = network["backend"] as? String ?? "standalone"
            networkHelperAvailable = network["helperAvailable"] as? Bool == true
            networkCanInitialize = network["canInitialize"] as? Bool == true
            hasCheckedApplicationEnvironment = true
            upstreamProxySummary = network["upstreamSummary"] as? String ?? "不使用前置"
            setupReport = makeSetupReport(network: network, browser: browser)
        } catch {
            networkHelperAvailable = false
            networkCanInitialize = false
            hasCheckedApplicationEnvironment = true
            setupReport = EnvironmentSetupReport(
                isInitialized: false, networkReady: false, hasManagedConfiguration: activeProfileID != nil,
                canInitialize: false, needsBrowserRestart: browser.restartRequired,
                requiresManualWebRTC: browser.state == .unsupported || browser.requiresFileAccess,
                requiresBrowserFileAccess: browser.requiresFileAccess,
                hasNetworkConflict: false, conflictMessage: "",
                message: error.localizedDescription,
                checks: [EnvironmentSetupCheck(id: "network", title: "网络环境", detail: error.localizedDescription, state: .unavailable),
                         browserCheck(browser)])
        }
    }

    private func browserCheck(_ browser: BrowserEnvironmentStatus) -> EnvironmentSetupCheck {
        EnvironmentSetupCheck(id: "webrtc", title: "浏览器 WebRTC", detail: browser.summary + "。" + browser.details,
                              state: browser.isReady ? .ready : (browser.state == .unsupported || browser.state == .error ? .unavailable : .actionRequired))
    }

    private func makeSetupReport(network: [String: Any], browser: BrowserEnvironmentStatus) -> EnvironmentSetupReport {
        let networkReady = network["networkReady"] as? Bool ?? false
        let checks = (network["checks"] as? [[String: Any]] ?? []).map { item in
            let id = item["id"] as? String ?? UUID().uuidString
            let planned = ["managedScript", "dnsProtection", "activeRuntime", "routeProtection", "configurationMatch"].contains(id)
            return EnvironmentSetupCheck(id: id,
                                  title: item["title"] as? String ?? "环境检查",
                                  detail: item["detail"] as? String ?? "",
                                  state: item["ready"] as? Bool == true ? .ready : (planned ? .pending : .actionRequired))
        }
        let initialized = networkReady && browser.isReady
        let conflicts = network["conflicts"] as? [String] ??
            (network["conflicts"] as? [[String: String]] ?? []).map { item in
                [item["name"], item["detail"]].compactMap { $0 }.joined(separator: "：")
            }
        let conflictMessage = network["conflictMessage"] as? String ?? conflicts.joined(separator: "；")
        let hasNetworkConflict = network["hasNetworkConflict"] as? Bool ?? !conflicts.isEmpty
        let message: String
        if initialized { message = "初始化已完成，添加其他账号后即可切换。" }
        else if networkReady { message = "网络已配置；" + browser.summary }
        else { message = network["message"] as? String ?? "添加账号并完成首次初始化。" }
        return EnvironmentSetupReport(
            isInitialized: initialized, networkReady: networkReady,
            hasManagedConfiguration: network["isManaged"] as? Bool ?? networkReady,
            canInitialize: !hasNetworkConflict && (network["canInitialize"] as? Bool == true),
            needsBrowserRestart: browser.restartRequired, requiresManualWebRTC: browser.state == .unsupported || browser.requiresFileAccess,
            requiresBrowserFileAccess: browser.requiresFileAccess,
            hasNetworkConflict: hasNetworkConflict, conflictMessage: conflictMessage,
            message: hasNetworkConflict ? conflictMessage : message,
            checks: checks + [browserCheck(browser)])
    }

    func prepareApplication() async {
        guard !isBusy, !isCheckingEnvironment else { return }
        isBusy = true
        defer { isBusy = false }
        applicationPreparationDiagnostic = nil
        serviceAuthorizationState = StandaloneBackgroundService.authorizationState
        do {
            // Application-wide authorization only; no account apply/initialize or browser action is issued.
            if serviceAuthorizationState == .notInstalled {
                try StandaloneBackgroundService.register()
                serviceAuthorizationState = StandaloneBackgroundService.authorizationState
            }
            await updateEnvironmentReport()
            switch serviceAuthorizationState {
            case .authorized:
                statusMessage = applicationPrepared
                    ? "软件的网络功能已就绪，所有账号共用；回到主界面选择账号后启用。"
                    : "系统已授权，网络组件还未响应。请稍后重新检查。"
            case .requiresApproval:
                statusMessage = "还需你在 macOS 系统设置中允许 ccmiss；这项授权适用于所有账号。"
            case .notInstalled:
                statusMessage = "网络授权尚未完成，请点击允许管理网络后按系统提示操作。"
            case .unknown, .unavailable:
                statusMessage = "暂时无法确认软件网络功能，请重新检查；仍沿用当前网络。"
            }
        } catch {
            let registrationError = error as NSError
            applicationPreparationDiagnostic = "\(registrationError.domain) (\(registrationError.code)): \(registrationError.localizedDescription)"
            await updateEnvironmentReport()
            if applicationPrepared {
                statusMessage = "软件的网络功能已就绪，所有账号共用；回到主界面选择账号后启用。"
                applicationPreparationDiagnostic = nil
            } else if serviceAuthorizationState == .requiresApproval {
                statusMessage = "macOS 正在等待你确认。请点击“打开系统授权”允许 ccmiss，然后重新检查。"
            } else if serviceAuthorizationState == .authorized {
                statusMessage = "系统已授权，网络组件还未响应。请稍后重新检查。"
            } else {
                statusMessage = "macOS 未完成网络授权，请重试；具体原因可在诊断详情中查看。"
            }
        }
    }

    func configureBrowserProtection() async {
        guard !isBusy, !isCheckingEnvironment else { return }
        isBusy = true
        defer { isBusy = false }
        // Browser protection is a separate explicit, application-wide action.
        browserProtectionStatus = BrowserEnvironmentService.initialize()
        await updateEnvironmentReport()
        statusMessage = browserProtectionSummary
    }

    func openBackgroundServiceSettings() { StandaloneBackgroundService.openSettings() }

    func configureUpstream(url: String) async {
        guard !isBusy, !isCheckingEnvironment else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await engine.request("configureUpstream", payload: ["url": url])
            upstreamProxySummary = result["upstreamSummary"] as? String ?? "不使用前置"
            statusMessage = "前置连接已保存，下次初始化或切换时生效；当前网络保持原状。"
            await updateEnvironmentReport()
        } catch { statusMessage = "前置连接未保存：" + error.localizedDescription }
    }

    func openBrowserAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func startStatusMonitoring() {
        visibleWindowCount += 1
        guard statusMonitorTask == nil else { return }
        refreshClaudeExit(force: false)
        statusMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                guard let self else { return }
                await self.pollRuntimeStatus()
                self.refreshClaudeExit(force: false)
            }
        }
    }

    func stopStatusMonitoring() {
        visibleWindowCount = max(0, visibleWindowCount - 1)
        guard visibleWindowCount == 0 else { return }
        statusMonitorTask?.cancel()
        statusMonitorTask = nil
        if isCheckingClaudeExit { invalidateClaudeExit() }
    }

    private func pollRuntimeStatus() async {
        guard bootstrapped, !isBusy, !isCheckingEnvironment else { return }
        let revision = networkOperationRevision
        do {
            let status = try await engine.request("status", payload: [:])
            guard !Task.isCancelled, !isBusy, revision == networkOperationRevision else { return }
            let current = RuntimeState(engineStatus: engineStatus, profileID: activeProfileID, scope: appliedScope,
                                       proxyMode: proxyMode, modeKnown: isProxyModeKnown, needsAttention: proxyModeNeedsAttention)
            let latest = runtimeState(from: status)
            // Even an unchanged mode can report a new exit IP or backend.
            applyStatus(status)
            guard current != latest else { return }
            lastVerification = nil
            statusMessage = engineStatus.message.isEmpty ? "网络运行状态已变化，请重新检测出口。" : engineStatus.message
            await updateEnvironmentReport()
        } catch {
            guard !Task.isCancelled, !isBusy, revision == networkOperationRevision else { return }
            invalidateClaudeExit()
            lastVerification = nil
            engineStatus = EngineStatus(isRunning: false, tunEnabled: false, mode: "状态暂不可用", message: error.localizedDescription, needsReapply: true)
            isProxyModeKnown = false
            proxyModeNeedsAttention = true
            statusMessage = "运行状态检查失败：" + error.localizedDescription
            activationNotice = AppActivationNotice(message: "暂时无法确认当前网络状态，请重新检查。", nextAction: .retry)
            setupReport = nil
        }
    }

    func addProfile(name: String, accountDescription: String, uri: String) async throws {
        guard !isBusy else { throw AppOperationError.message("正在执行另一项操作，请稍后重试。") }
        try persistNewProfile(name: name, accountDescription: accountDescription, uri: uri)
        statusMessage = "配置已保存。点击“启用此配置”后生效。"
    }

    private func persistNewProfile(name: String, accountDescription: String, uri: String) throws {
        let parsed = try SOCKSProxy(uri: uri)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw AppOperationError.message("请填写配置名称。") }
        let profile = ProxyProfile(name: cleanName, accountDescription: accountDescription, host: parsed.host, port: parsed.port, username: parsed.username)
        try store.saveURI(parsed.canonicalURI, for: profile.id)
        do { try store.saveProfiles(profiles + [profile]) }
        catch { try? store.deleteURI(for: profile.id); throw error }
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    func updateProfile(id: UUID, name: String, accountDescription: String, uri: String) async throws {
        guard !isBusy else { throw AppOperationError.message("正在执行另一项操作，请稍后重试。") }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw AppOperationError.message("找不到要修改的配置。") }
        let parsed = try SOCKSProxy(uri: uri)
        let old = profiles[index]
        let oldURI = try savedURIIfPresent(for: id)
        var updated = old
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.accountDescription = accountDescription
        updated.host = parsed.host
        updated.port = parsed.port
        updated.username = parsed.username
        updated.updatedAt = Date()
        var next = profiles
        next[index] = updated
        try store.saveURI(parsed.canonicalURI, for: id)
        do { try store.saveProfiles(next) }
        catch { restoreSavedURI(oldURI, for: id); throw error }
        profiles = next
        if id == activeProfileID && parsed.canonicalURI != oldURI {
            let requestedScope = appliedScope ?? routingScope
            networkOperationRevision &+= 1
            isBusy = true
            lastVerification = nil
            statusMessage = "正在应用当前账号的新代理设置…"
            defer { finishNetworkOperation() }
            do {
                let result = try await apply(updated, uri: parsed.canonicalURI, scope: requestedScope)
                acceptAppliedScope(result, fallback: requestedScope)
                acceptVerification(result)
                statusMessage = "当前账号配置已更新并应用。"
            } catch {
                restoreSavedURI(oldURI, for: id)
                profiles[index] = old
                try? store.saveProfiles(profiles)
                if let status = try? await engine.request("status", payload: [:]) { applyStatus(status) }
                statusMessage = "新配置未应用，已保留原账号设置。" + error.localizedDescription
                throw error
            }
        } else {
            statusMessage = id == activeProfileID ? "账号名称和描述已保存。" : "配置已保存。点击“启用此配置”后生效。"
        }
    }

    func deleteProfile(_ profile: ProxyProfile) async throws {
        guard !isBusy else { throw AppOperationError.message("正在切换，请稍后重试。") }
        guard profile.id != activeProfileID else { throw AppOperationError.message("这个账号正在使用中。请先切换到其他账号，或恢复接管前配置。") }
        let oldURI = try savedURIIfPresent(for: profile.id)
        let next = profiles.filter { $0.id != profile.id }
        try store.deleteURI(for: profile.id)
        do { try store.saveProfiles(next) }
        catch { restoreSavedURI(oldURI, for: profile.id); throw error }
        profiles = next
        if selectedProfileID == profile.id { selectedProfileID = next.first?.id }
        statusMessage = "账号配置已删除。"
    }

    func proxyURI(for profile: ProxyProfile) throws -> String { try store.loadURI(for: profile.id) }

    private func savedURIIfPresent(for id: UUID) throws -> String? {
        do { return try store.loadURI(for: id) }
        catch ProfileStoreError.missingCredentials { return nil }
    }

    private func restoreSavedURI(_ uri: String?, for id: UUID) {
        if let uri { try? store.saveURI(uri, for: id) }
        else { try? store.deleteURI(for: id) }
    }

    private func notice(for readiness: AppSetupReadiness) -> AppActivationNotice {
        if usesClashCoexist, readiness.requirement == .networkUnavailable {
            let failed = setupReport?.checks.first { $0.id != "webrtc" && $0.state == .actionRequired }
            return AppActivationNotice(message: failed?.detail ?? readiness.summary, nextAction: .openSoftwareSettings)
        }
        if readiness.requirement == .conflict {
            let source = setupReport?.conflictMessage.lowercased() ?? ""
            let name = source.contains("clash") || source.contains("verge") ? "Clash" : "另一个代理或 VPN"
            return AppActivationNotice(message: "\(name) 正在管理当前网络。请在现有任务结束后退出它，再点启用；ccmiss 不会替你关闭它。", nextAction: .openSoftwareSettings)
        }
        if readiness.requirement == .networkUnavailable,
           let check = setupReport?.checks.first(where: { $0.id != "webrtc" && $0.state != .ready }) {
            switch check.id {
            case "dnsRecovery":
                return AppActivationNotice(message: "上次网络恢复还没完成。请先点击“跟随系统代理”重试恢复，再启用账号。", nextAction: .none)
            case "physicalInterface":
                return AppActivationNotice(message: "当前没有可用的网络连接，请先连接 Wi-Fi 或网线。", nextAction: .retry)
            case "ipv6":
                return AppActivationNotice(message: "当前网络还有尚未受保护的 IPv6 连接，暂不能启用账号。可在软件设置中查看处理说明。", nextAction: .openSoftwareSettings)
            case "ownership":
                return AppActivationNotice(message: "另一个 Mac 用户正在使用本软件的网络功能，请先结束那边的使用。", nextAction: .retry)
            case "bundledCore":
                return AppActivationNotice(message: "软件的网络组件不完整，请重新安装完整的 ccmiss。", nextAction: .openSoftwareSettings)
            default: break
            }
        }
        return AppActivationNotice(message: readiness.summary, nextAction: readiness.nextAction)
    }

    func activateProfile(_ profile: ProxyProfile, reapply: Bool = false) async {
        guard !isBusy, !isCheckingEnvironment else { return }
        guard reapply || accountNetworkAction(for: profile) != .stop else {
            statusMessage = "这个账号已启用，可点击“停用并恢复系统网络”退出账号出口。"
            return
        }
        guard profiles.contains(where: { $0.id == profile.id }) else {
            activationNotice = AppActivationNotice(message: "找不到这个账号，请重新选择。", nextAction: .none)
            return
        }
        networkOperationRevision &+= 1
        isBusy = true
        activationNotice = nil
        activationPreconditionBlocked = false
        statusMessage = "正在启用“\(profile.name)”…"
        defer { finishNetworkOperation() }
        do {
            // Recheck shared permission and network conditions, without changing browser settings.
            await updateEnvironmentReport(inspectBrowser: false)
            let readiness = self.readiness(isBusy: false)
            guard readiness.canActivate else {
                let blocked = notice(for: readiness)
                activationNotice = blocked
                activationPreconditionBlocked = true
                statusMessage = blocked.message
                return
            }
            let requestedScope: RoutingScope = usesClashCoexist ? .servicesOnly : routingScope
            lastVerification = nil
            // apply supports the first account too; prior account history is not a prerequisite.
            let result = try await apply(profile, uri: store.loadURI(for: profile.id), scope: requestedScope)
            acceptAppliedScope(result, fallback: requestedScope)
            activeProfileID = profile.id
            selectedProfileID = profile.id
            if let status = try? await engine.request("status") { applyStatus(status) }
            acceptVerification(result)
            statusMessage = usesClashCoexist
                ? "已启用“\(profile.name)”的指定服务出口；新连接使用所选 IP，现有连接继续原出口直到结束。"
                : "已启用“\(profile.name)”。"
            activationNotice = nil
        } catch {
            statusMessage = "启用未完成：" + error.localizedDescription
            if let status = try? await engine.request("status") { applyStatus(status) }
            else { isProxyModeKnown = false; proxyModeNeedsAttention = true }
            let detail = error.localizedDescription
            let message: String
            let nextAction: AppSetupNextAction
            if detail.contains("自动恢复未完成") {
                message = "切换“\(profile.name)”失败，恢复尚未确认。请先点击“停用并恢复系统网络”尝试恢复，再查看诊断。"
                nextAction = .openSoftwareSettings
            } else {
                let reason = detail.replacingOccurrences(of: " 已恢复切换前配置。", with: "")
                let current: String
                if isProxyModeKnown, proxyMode == .profile, engineStatus.isOperational,
                   let active = profiles.first(where: { $0.id == activeProfileID }) {
                    current = " 当前仍在使用“\(active.name)”（\(active.host)）。"
                } else if isProxyModeKnown, proxyMode == .system {
                    current = " 当前沿用原有系统网络。"
                } else { current = " 请先确认当前网络状态。" }
                message = "未能切换到“\(profile.name)”：" + String(reason.prefix(280)) + current
                nextAction = .retryActivation
            }
            activationNotice = AppActivationNotice(message: message, nextAction: nextAction)
        }
        await updateEnvironmentReport(inspectBrowser: false)
    }

    private func apply(_ profile: ProxyProfile, uri: String, scope: RoutingScope? = nil) async throws -> [String: Any] {
        let requestedScope: RoutingScope = usesClashCoexist ? .servicesOnly : (scope ?? routingScope)
        let payload: [String: Any] = ["scope": requestedScope.rawValue, "profile": ["id": profile.id.uuidString, "name": profile.name, "accountDescription": profile.accountDescription, "socksURL": uri]]
        let result = try await engine.request("apply", payload: payload)
        guard result["success"] as? Bool == true else { throw AppOperationError.message(result["details"] as? String ?? "代理检测未通过，原配置已保留。") }
        return result
    }

    func refreshStatus() async {
        guard !isBusy else { return }
        networkOperationRevision &+= 1
        isBusy = true
        lastVerification = nil
        statusMessage = "正在检查独立内核和实际出口…"
        defer { finishNetworkOperation() }
        var didReadRuntimeStatus = false
        do {
            let status = try await engine.request("status", payload: [:])
            applyStatus(status)
            didReadRuntimeStatus = true
            if status["isRunning"] as? Bool == true {
                let result = try await engine.request("verify", payload: [:])
                acceptVerification(result)
                statusMessage = result["details"] as? String ?? "出口检测完成。"
            } else { statusMessage = status["message"] as? String ?? "独立网络服务尚未启用。" }
        } catch {
            if !didReadRuntimeStatus {
                isProxyModeKnown = false
                proxyModeNeedsAttention = true
                activationNotice = AppActivationNotice(message: "暂时无法确认当前网络状态，请重新检查。", nextAction: .retry)
            }
            statusMessage = error.localizedDescription
            lastVerification = nil
        }
        await updateEnvironmentReport()
    }

    func restorePreviousConfiguration() async {
        await followSystemProxy()
    }

    func followSystemProxy() async {
        guard !isBusy, !isCheckingEnvironment else { return }
        networkOperationRevision &+= 1
        isBusy = true
        activationNotice = nil
        activationPreconditionBlocked = false
        statusMessage = "正在停用账号并恢复系统网络…"
        defer { finishNetworkOperation() }
        do {
            let result = try await engine.request("useSystemProxy")
            guard result["success"] as? Bool == true, result["proxyMode"] as? String == ProxyMode.system.rawValue else {
                throw AppOperationError.message(result["details"] as? String ?? "尚未确认本软件已退出接管，请重试。")
            }
            activeProfileID = nil
            appliedScope = nil
            lastVerification = nil
            proxyMode = .system
            isProxyModeKnown = true
            proxyModeNeedsAttention = false
            engineStatus = EngineStatus(mode: "跟随系统代理", message: result["details"] as? String ?? "沿用系统当前代理与路由。")
            if let status = try? await engine.request("status", payload: [:]) { applyStatus(status) }
            statusMessage = result["details"] as? String ?? "已切换为跟随系统代理。"
        } catch {
            if let status = try? await engine.request("status") { applyStatus(status) }
            else { isProxyModeKnown = false; proxyModeNeedsAttention = true }
            statusMessage = "恢复系统网络未完成：" + error.localizedDescription
            activationNotice = AppActivationNotice(message: "尚未确认已退出 ccmiss 的代理。请重新检查软件设置；当前账号与恢复资料会保留。", nextAction: .openSoftwareSettings)
        }
        await updateEnvironmentReport()
    }

    private func applyStatus(_ value: [String: Any]) {
        let backend = value["backend"] as? String ?? "standalone"
        let newReportedIP = (value["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let state = runtimeState(from: value)
        let current = RuntimeState(engineStatus: engineStatus, profileID: activeProfileID, scope: appliedScope,
                                   proxyMode: proxyMode, modeKnown: isProxyModeKnown, needsAttention: proxyModeNeedsAttention)
        if current != state || backend != networkBackend || newReportedIP != reportedExitIP { invalidateClaudeExit() }
        networkBackend = backend
        if !state.engineStatus.isOperational || state.profileID != activeProfileID || state.scope != appliedScope {
            lastVerification = nil
        }
        reportedExitIP = newReportedIP
        if let verification = lastVerification,
           verificationProfileID != state.profileID || (verification.success && reportedExitIP != nil && verification.ip != reportedExitIP) {
            lastVerification = nil
        }
        activeProfileID = state.profileID
        appliedScope = state.scope
        engineStatus = state.engineStatus
        proxyMode = state.proxyMode
        isProxyModeKnown = state.modeKnown
        proxyModeNeedsAttention = state.needsAttention
    }

    private struct RuntimeState: Equatable {
        let engineStatus: EngineStatus
        let profileID: UUID?
        let scope: RoutingScope?
        let proxyMode: ProxyMode
        let modeKnown: Bool
        let needsAttention: Bool

        static func == (lhs: RuntimeState, rhs: RuntimeState) -> Bool {
            lhs.engineStatus.isRunning == rhs.engineStatus.isRunning &&
            lhs.engineStatus.tunEnabled == rhs.engineStatus.tunEnabled &&
            lhs.engineStatus.needsReapply == rhs.engineStatus.needsReapply &&
            lhs.engineStatus.mode == rhs.engineStatus.mode &&
            lhs.profileID == rhs.profileID && lhs.scope == rhs.scope &&
            lhs.proxyMode == rhs.proxyMode && lhs.modeKnown == rhs.modeKnown && lhs.needsAttention == rhs.needsAttention
        }
    }

    private func runtimeState(from value: [String: Any]) -> RuntimeState {
        let isRunning = value["isRunning"] as? Bool ?? false
        let coexist = value["backend"] as? String == "clashCoexist"
        let tunEnabled = value["tunEnabled"] as? Bool ?? false
        let coreMode = value["mode"] as? String ?? "unknown"
        let profileID = (value["activeProfileID"] as? String).flatMap(UUID.init(uuidString:))
        let systemConfirmed = value["systemProxyConfirmed"] as? Bool == true
        let scope = systemConfirmed ? nil : (value["scope"] as? String).flatMap(RoutingScope.init(rawValue:))
        let reportedProxyMode = (value["proxyMode"] as? String).flatMap(ProxyMode.init(rawValue:))
        let ipv6Unsafe = value["ipv6Safe"] as? Bool == false
        let needsReapply = !systemConfirmed && (ipv6Unsafe || (value["needsReapply"] as? Bool ?? false) || (isRunning && scope != nil && coreMode != "rule"))
        let effectiveProfileID = needsReapply || systemConfirmed ? nil : profileID
        let savedRange = scope.map { value["scopeLabel"] as? String ?? (coexist ? "Clash 共存 · 指定服务" : rangeName($0)) }
        let mode: String
        if systemConfirmed {
            mode = "跟随系统代理"
        } else if !isRunning {
            mode = savedRange.map { "\($0)（独立内核未运行）" } ?? "独立内核未运行"
        } else if ipv6Unsafe {
            mode = "IPv6 路由未受保护"
        } else if needsReapply {
            mode = "配置已变化，需重新应用"
        } else if !tunEnabled {
            mode = savedRange.map { "\($0)（TUN 未启用）" } ?? "TUN 未启用"
        } else if profileID != nil, let savedRange {
            mode = savedRange
        } else {
            mode = "沿用当前网络"
        }
        let engine = EngineStatus(isRunning: isRunning, tunEnabled: tunEnabled, mode: mode, message: value["message"] as? String ?? "", needsReapply: needsReapply)
        let actualMode: ProxyMode = systemConfirmed ? .system : (reportedProxyMode ?? (isRunning || needsReapply ? .profile : .system))
        let modeKnown = systemConfirmed || reportedProxyMode == .profile || isRunning
        return RuntimeState(engineStatus: engine, profileID: effectiveProfileID, scope: scope,
                            proxyMode: actualMode, modeKnown: modeKnown,
                            needsAttention: !systemConfirmed && !engine.isOperational)
    }

    private func acceptAppliedScope(_ result: [String: Any], fallback: RoutingScope) {
        networkBackend = result["backend"] as? String ?? networkBackend
        let scope = (result["scope"] as? String).flatMap(RoutingScope.init(rawValue:)) ?? fallback
        appliedScope = scope
        proxyMode = .profile
        isProxyModeKnown = true
        proxyModeNeedsAttention = false
        // A successful apply has already passed the engine's live TUN verification.
        engineStatus = EngineStatus(isRunning: true, tunEnabled: true, mode: result["scopeLabel"] as? String ?? rangeName(scope), message: engineStatus.message)
        reportedExitIP = (result["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func rangeName(_ scope: RoutingScope) -> String {
        scope == .fullPublic ? "公网 TCP（保留业务直连）" : "指定服务"
    }

    private func acceptVerification(_ result: [String: Any]) {
        guard let profileID = (result["activeProfileID"] as? String).flatMap(UUID.init(uuidString:)),
              profileID == activeProfileID else {
            lastVerification = nil
            verificationProfileID = nil
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = (result["checkedAt"] as? String).flatMap { formatter.date(from: $0) } ?? Date()
        let ip = (result["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let expectedIP = result["expectedIP"] as? String ?? ""
        let consistent = ip != nil && !expectedIP.isEmpty && ip == expectedIP && (reportedExitIP == nil || ip == reportedExitIP)
        let success = result["success"] as? Bool == true && consistent
        var details = result["details"] as? String ?? ""
        if result["success"] as? Bool == true && !consistent {
            details = "出口检测与当前账号状态不一致，请重新检测。" + details
        }
        verificationProfileID = profileID
        lastVerification = ExitVerification(ip: ip, expectedIP: expectedIP, checkedAt: time, success: success, details: details)
    }
}
