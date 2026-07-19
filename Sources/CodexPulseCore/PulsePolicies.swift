import Foundation

public enum PulseRefreshPolicy {
    public static func interval(codexRunning: Bool, visibility: PulseVisibility) -> TimeInterval? {
        guard codexRunning else { return nil }
        return visibility == .active ? 0.5 : 30
    }
}

public struct StatusItemHealth: Equatable, Sendable {
    public let isVisible: Bool
    public let hasButton: Bool
    public let hasWindow: Bool
    public let hasScreen: Bool
    public let width: Double

    public init(isVisible: Bool, hasButton: Bool, hasWindow: Bool, hasScreen: Bool, width: Double) {
        self.isVisible = isVisible
        self.hasButton = hasButton
        self.hasWindow = hasWindow
        self.hasScreen = hasScreen
        self.width = width
    }

    public var isReachable: Bool {
        isVisible && hasButton && hasWindow && hasScreen && width > 0
    }
}

public enum StatusItemRecoveryAction: Equatable, Sendable {
    case none
    case refresh
    case rebuild
    case guideUser
}

public enum StatusItemRecoveryPolicy {
    public static func action(for health: StatusItemHealth, attempt: Int) -> StatusItemRecoveryAction {
        guard !health.isReachable else { return .none }
        switch attempt {
        case ..<1: return .refresh
        case 1: return .rebuild
        default: return .guideUser
        }
    }
}
