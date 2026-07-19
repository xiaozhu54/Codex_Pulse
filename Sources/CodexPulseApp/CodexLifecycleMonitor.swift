import AppKit

@MainActor
final class CodexLifecycleMonitor {
    nonisolated static let codexBundleIdentifier = "com.openai.codex"

    var onRunningChanged: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    var isCodexRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.codexBundleIdentifier
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard Self.bundleIdentifier(from: notification) == Self.codexBundleIdentifier else { return }
            MainActor.assumeIsolated { self?.onRunningChanged?(true) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard Self.bundleIdentifier(from: notification) == Self.codexBundleIdentifier else { return }
            MainActor.assumeIsolated { self?.onRunningChanged?(false) }
        })
        let initiallyRunning = isCodexRunning
        Task { @MainActor [weak self] in
            // Creating an NSStatusItem synchronously from
            // applicationDidFinishLaunching can leave its window detached from
            // every screen on macOS 26. Deliver the initial state after AppKit
            // finishes the current launch callback.
            self?.onRunningChanged?(initiallyRunning)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    nonisolated private static func bundleIdentifier(from notification: Notification) -> String? {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return application?.bundleIdentifier
    }
}
