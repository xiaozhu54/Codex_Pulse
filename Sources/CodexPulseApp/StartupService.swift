import Foundation
import ServiceManagement

@MainActor
enum StartupService {
    static let helperIdentifier = "com.origami.codexpulse.monitor"

    static func setEnabled(_ enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/CodexPulseMonitor.app")
        guard FileManager.default.fileExists(atPath: helperURL.path) else { return }

        let service = SMAppService.loginItem(identifier: helperIdentifier)
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            // Do not log file paths or user content. The setting remains user-controlled.
        }
    }
}
