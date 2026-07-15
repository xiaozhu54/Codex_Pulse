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
    private let statusBar = StatusBarController()
    private var engine: CodexPulseEngine!
    private var refreshTimer: Timer?
    private var wasCodexRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        rebuildEngine()
        statusBar.actions = StatusBarActions(
            toggleDynamicIcon: { [weak self] value in self?.setDynamicIcon(value) },
            toggleLaunchWithCodex: { [weak self] value in self?.setLaunchWithCodex(value) },
            pinSession: { [weak self] id in self?.pinSession(id) },
            restoreAutomatic: { [weak self] in self?.pinSession(nil) },
            chooseCodexHome: { [weak self] in self?.chooseCodexHome() },
            quit: { NSApp.terminate(nil) }
        )

        if preferences.value.launchWithCodex {
            StartupService.setEnabled(true)
        }
        lifecycle.onRunningChanged = { [weak self] running in
            self?.handleCodexRunning(running)
        }
        lifecycle.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        lifecycle.stop()
    }

    private func handleCodexRunning(_ running: Bool) {
        if running {
            statusBar.show()
            startRefreshTimer()
            refresh()
        } else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            statusBar.hide()
            if wasCodexRunning {
                NSApp.terminate(nil)
            }
        }
        wasCodexRunning = running
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh() {
        let currentPreferences = preferences.value
        do {
            let snapshot = try engine.snapshot(
                codexRunning: lifecycle.isCodexRunning,
                preferences: currentPreferences
            )
            let sessions = (try? engine.availableSessions(
                pinnedSessionID: currentPreferences.pinnedSessionID
            )) ?? []
            statusBar.render(snapshot: snapshot, sessions: sessions, preferences: currentPreferences)
        } catch {
            let selection: SessionSelectionMode = currentPreferences.pinnedSessionID == nil
                ? .automatic
                : .pinnedUnavailable
            let snapshot = StatusSnapshot(
                visibility: lifecycle.isCodexRunning ? .idle : .hidden,
                sessionID: currentPreferences.pinnedSessionID,
                selectionMode: selection,
                stage: .unavailable,
                updatedAt: Date(),
                dynamicIconEnabled: currentPreferences.dynamicIconEnabled
            )
            statusBar.render(snapshot: snapshot, sessions: [], preferences: currentPreferences)
        }
    }

    private func setDynamicIcon(_ enabled: Bool) {
        preferences.setDynamicIcon(enabled)
        refresh()
    }

    private func setLaunchWithCodex(_ enabled: Bool) {
        preferences.setLaunchWithCodex(enabled)
        StartupService.setEnabled(enabled)
        refresh()
    }

    private func pinSession(_ id: String?) {
        preferences.setPinnedSession(id)
        refresh()
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
        rebuildEngine()
        refresh()
    }

    private func rebuildEngine() {
        engine = CodexPulseEngine(codexHome: preferences.codexHome)
    }
}
