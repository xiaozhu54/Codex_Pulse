import AppKit
import CodexPulseCore

@main
@MainActor
struct CodexPulseMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferencesStore()
    private let lifecycle = CodexLifecycleMonitor()
    private lazy var statusBar = StatusBarController()
    private let statusItemHealth = StatusItemHealthMonitor()
    private let fileEvents = CodexFileEventMonitor()
    private var runtime: PulseRuntime!
    private var refreshTimer: Timer?
    private var refreshTimerInterval: TimeInterval?
    private var refreshTask: Task<Void, Never>?
    private var activeRefreshID: UUID?
    private var refreshPending = false
    private var runtimeGeneration = 0
    private var pendingRuntimeHome: URL?
    private var applicationModel = PulseApplicationModel()
    private var startupMonitorStatus: LaunchMonitorStatus = .unknown

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildRuntime()
        statusBar.actions = StatusBarActions(
            toggleDynamicIcon: { [weak self] value in self?.setDynamicIcon(value) },
            toggleLaunchWithCodex: { [weak self] value in self?.setLaunchWithCodex(value) },
            pinSession: { [weak self] id in self?.pinSession(id) },
            restoreAutomatic: { [weak self] in self?.pinSession(nil) },
            chooseCodexHome: { [weak self] in self?.chooseCodexHome() },
            quit: { NSApp.terminate(nil) }
        )
        statusItemHealth.inspect = { [weak self] in
            self?.statusBar.health() ?? StatusItemHealth(
                isVisible: false,
                hasButton: false,
                hasWindow: false,
                hasScreen: false,
                width: 0
            )
        }
        statusItemHealth.recover = { [weak self] action in self?.statusBar.recover(action) }

        startupMonitorStatus = StartupService.setEnabled(preferences.value.launchWithCodex)
        lifecycle.onRunningChanged = { [weak self] running in self?.handleCodexRunning(running) }
        lifecycle.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopObservation()
        lifecycle.stop()
    }

    private func handleCodexRunning(_ running: Bool) {
        let update = applicationModel.lifecycleChanged(
            codexRunning: running,
            preferences: preferences.value,
            codexHomePath: preferences.codexHome.path,
            launchMonitorStatus: startupMonitorStatus
        )
        statusBar.render(update.viewState)
        if running {
            statusItemHealth.start()
            fileEvents.start(codexHome: preferences.codexHome) { [weak self] in
                self?.handleFileEvent()
            }
            configureRefreshTimer(interval: update.refreshInterval)
            if update.shouldRefresh { requestRefresh() }
        } else {
            stopObservation()
            if update.shouldTerminate { NSApp.terminate(nil) }
        }
    }

    private func requestRefresh() {
        guard lifecycle.isCodexRunning else { return }
        if refreshTask != nil {
            refreshPending = true
            return
        }
        let generation = runtimeGeneration
        let refreshID = UUID()
        activeRefreshID = refreshID
        let request = PulseRefreshRequest(
            codexRunning: true,
            pinnedSessionID: preferences.value.pinnedSessionID
        )
        let runtime = self.runtime!
        refreshTask = Task { [weak self] in
            let state = await runtime.refresh(request)
            guard let self else { return }
            self.finishRefresh(state, generation: generation, refreshID: refreshID)
        }
    }

    private func finishRefresh(_ state: PulseState, generation: Int, refreshID: UUID) {
        guard activeRefreshID == refreshID else { return }
        refreshTask = nil
        activeRefreshID = nil
        if let pendingRuntimeHome {
            self.pendingRuntimeHome = nil
            runtime = PulseRuntime(codexHome: pendingRuntimeHome)
            refreshPending = false
            requestRefresh()
            return
        }
        if generation == runtimeGeneration {
            let update = applicationModel.accepted(
                state,
                preferences: preferences.value,
                codexHomePath: preferences.codexHome.path,
                launchMonitorStatus: startupMonitorStatus
            )
            statusBar.render(update.viewState)
            configureRefreshTimer(interval: update.refreshInterval)
            statusItemHealth.scheduleCheck()
        }
        if refreshPending {
            refreshPending = false
            requestRefresh()
        }
    }

    private func renderCurrentState() {
        let presentation = applicationModel.presented(
            preferences: preferences.value,
            codexHomePath: preferences.codexHome.path,
            launchMonitorStatus: startupMonitorStatus
        )
        statusBar.render(presentation)
    }

    private func handleFileEvent() {
        // Active tasks already refresh at the PRD's 500 ms cadence. Letting every
        // filesystem event trigger a refresh would make streamed writes bypass it.
        guard applicationModel.shouldRefreshForFileEvent else { return }
        requestRefresh()
    }

    private func configureRefreshTimer(interval: TimeInterval?) {
        guard interval != refreshTimerInterval else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTimerInterval = interval
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestRefresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopObservation() {
        runtimeGeneration += 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTimerInterval = nil
        refreshTask?.cancel()
        refreshTask = nil
        activeRefreshID = nil
        pendingRuntimeHome = nil
        refreshPending = false
        fileEvents.stop()
        statusItemHealth.stop()
    }

    private func setDynamicIcon(_ enabled: Bool) {
        preferences.setDynamicIcon(enabled)
        renderCurrentState()
        statusItemHealth.scheduleCheck()
    }

    private func setLaunchWithCodex(_ enabled: Bool) {
        let result = StartupService.setEnabled(enabled)
        startupMonitorStatus = result
        switch result {
        case .enabled, .requiresApproval:
            preferences.setLaunchWithCodex(true)
        case .disabled:
            preferences.setLaunchWithCodex(false)
        case .unavailable, .failed, .unknown:
            break
        }
        renderCurrentState()
        guard result == .failed || result == .requiresApproval || result == .unavailable else { return }
        let alert = NSAlert()
        alert.messageText = result == .requiresApproval
            ? "需要在系统设置中允许后台项目"
            : "无法更新“随 Codex 启动”"
        alert.informativeText = result == .requiresApproval
            ? "请在“系统设置 → 通用 → 登录项与扩展”中允许 Codex Pulse Monitor。"
            : "当前应用包中未找到可用的启动监视器，或系统拒绝了注册。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func pinSession(_ id: String?) {
        preferences.setPinnedSession(id)
        requestRefresh()
    }

    private func chooseCodexHome() {
        let panel = NSOpenPanel()
        panel.title = "选择 CODEX_HOME"
        panel.message = "Codex Pulse 只读访问所选目录中的 sessions 与 SQLite 状态文件。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.codexHome
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.setCodexHome(url)
        rebuildRuntime()
        fileEvents.start(codexHome: preferences.codexHome) { [weak self] in self?.handleFileEvent() }
        requestRefresh()
    }

    private func rebuildRuntime() {
        runtimeGeneration += 1
        let home = preferences.codexHome
        guard refreshTask == nil else {
            // Finish the current short, read-only batch before switching roots.
            // This preserves global single-flight even though the synchronous
            // SQLite/JSONL adapters cannot cooperatively cancel mid-query.
            pendingRuntimeHome = home
            refreshPending = true
            return
        }
        pendingRuntimeHome = nil
        refreshPending = false
        runtime = PulseRuntime(codexHome: home)
    }
}
