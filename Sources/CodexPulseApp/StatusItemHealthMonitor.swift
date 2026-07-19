import AppKit
import CodexPulseCore

@MainActor
final class StatusItemHealthMonitor {
    var inspect: @MainActor () -> StatusItemHealth = {
        StatusItemHealth(isVisible: false, hasButton: false, hasWindow: false, hasScreen: false, width: 0)
    }
    var recover: @MainActor (StatusItemRecoveryAction) -> Void = { _ in }

    private var screenObserver: NSObjectProtocol?
    private var flagsMonitor: Any?
    private var checkWorkItem: DispatchWorkItem?
    private var attempt = 0
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCheck(after: 1) }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                if !event.modifierFlags.contains(.command) { self?.scheduleCheck(after: 0.35) }
            }
            return event
        }
        scheduleCheck(after: 2)
    }

    func stop() {
        running = false
        checkWorkItem?.cancel()
        checkWorkItem = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        screenObserver = nil
        flagsMonitor = nil
        attempt = 0
    }

    func scheduleCheck(after delay: TimeInterval = 0.25) {
        guard running else { return }
        checkWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.check() }
        checkWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func check() {
        guard running else { return }
        guard !NSEvent.modifierFlags.contains(.command) else {
            scheduleCheck(after: 0.4)
            return
        }
        let action = StatusItemRecoveryPolicy.action(for: inspect(), attempt: attempt)
        recover(action)
        if action == .none {
            attempt = 0
        } else {
            attempt += 1
            if action != .guideUser { scheduleCheck(after: 0.75) }
        }
    }
}

@MainActor
enum StatusItemPlacementPreflight {
    static func repairIfNeeded(autosaveName: String, defaults: UserDefaults = .standard) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard let number = defaults.object(forKey: key) as? NSNumber else { return }
        let position = number.doubleValue
        let totalWidth = NSScreen.screens.reduce(0.0) { $0 + Double($1.frame.width) }
        let maximumPlausiblePosition = max(totalWidth * 2, 4_096)
        if !position.isFinite || position <= 0 || position > maximumPlausiblePosition {
            defaults.removeObject(forKey: key)
        }
    }
}
