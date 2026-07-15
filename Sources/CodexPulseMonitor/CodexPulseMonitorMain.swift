import AppKit

@main
@MainActor
struct CodexPulseMonitorMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = MonitorDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class MonitorDelegate: NSObject, NSApplicationDelegate {
    nonisolated private static let codexBundleIdentifier = "com.openai.codex"
    private var observer: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard application?.bundleIdentifier == Self.codexBundleIdentifier else { return }
            MainActor.assumeIsolated { Self.launchMainApplication() }
        }

        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == Self.codexBundleIdentifier
        }) {
            Self.launchMainApplication()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private static func launchMainApplication() {
        let mainApplicationURL = containingApplication(for: Bundle.main.bundleURL)
        guard mainApplicationURL.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(
            at: mainApplicationURL,
            configuration: configuration
        ) { _, _ in }
    }

    private static func containingApplication(for helperBundleURL: URL) -> URL {
        var url = helperBundleURL
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}
