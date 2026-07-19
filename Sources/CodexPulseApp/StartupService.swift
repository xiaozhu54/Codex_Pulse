import CodexPulseCore
import Foundation
import ServiceManagement

@MainActor
enum StartupService {
    static let helperIdentifier = "com.origami.codexpulse.monitor"

    static func setEnabled(_ enabled: Bool) -> LaunchMonitorStatus {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/CodexPulseMonitor.app")
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            return enabled ? .unavailable : .disabled
        }

        let service = SMAppService.loginItem(identifier: helperIdentifier)
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            let actual = status(of: service)
            if enabled, actual == .enabled || actual == .requiresApproval { return actual }
            if !enabled, actual == .disabled || actual == .unavailable { return actual }
            return .failed
        }
        return status(of: service)
    }

    private static func status(of service: SMAppService) -> LaunchMonitorStatus {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unknown
        }
    }
}
