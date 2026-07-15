import Foundation

public struct PulsePreferences: Equatable, Sendable {
    public var dynamicIconEnabled: Bool
    public var launchWithCodex: Bool
    public var pinnedSessionID: String?

    public init(
        dynamicIconEnabled: Bool = false,
        launchWithCodex: Bool = true,
        pinnedSessionID: String? = nil
    ) {
        self.dynamicIconEnabled = dynamicIconEnabled
        self.launchWithCodex = launchWithCodex
        self.pinnedSessionID = pinnedSessionID
    }
}

public enum PulseVisibility: Equatable, Sendable {
    case hidden
    case idle
    case active
}

public enum SessionSelectionMode: Equatable, Sendable {
    case automatic
    case pinned
    case pinnedUnavailable
}

public struct SessionSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let model: String?
    public let isActive: Bool
    public let updatedAt: Date

    public init(id: String, title: String, model: String?, isActive: Bool, updatedAt: Date) {
        self.id = id
        self.title = title
        self.model = model
        self.isActive = isActive
        self.updatedAt = updatedAt
    }
}

public enum TaskStage: String, Equatable, Sendable {
    case idle
    case thinking
    case generating
    case usingTool
    case waitingForTool
    case waitingForApproval
    case finishing
    case unavailable

    public var displayName: String {
        switch self {
        case .idle: "空闲"
        case .thinking: "推理中"
        case .generating: "生成中"
        case .usingTool: "调用工具"
        case .waitingForTool: "等待工具"
        case .waitingForApproval: "等待审批"
        case .finishing: "收尾中"
        case .unavailable: "状态不可用"
        }
    }
}

public struct TokenSpeed: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case estimating
        case final
        case thinking
        case unavailable
    }

    public let kind: Kind
    public let tokensPerSecond: Double?
    public let recentAverage: Double?

    public init(kind: Kind, tokensPerSecond: Double? = nil, recentAverage: Double? = nil) {
        self.kind = kind
        self.tokensPerSecond = tokensPerSecond
        self.recentAverage = recentAverage
    }

    public static let unavailable = TokenSpeed(kind: .unavailable)

    public var compactText: String {
        switch (kind, tokensPerSecond) {
        case (.estimating, let value?): "≈\(Self.format(value)) t/s"
        case (.final, let value?): "\(Self.format(value)) t/s"
        case (.thinking, _): "推理中…"
        default: "— t/s"
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

public struct StatusSnapshot: Equatable, Sendable {
    public let visibility: PulseVisibility
    public let weeklyRemainingPercent: Double?
    public let weeklyResetsAt: Date?
    public let tokenSpeed: TokenSpeed
    public let model: String?
    public let contextAvailablePercent: Double?
    public let contextUsedTokens: Int?
    public let contextWindowTokens: Int?
    public let sessionID: String?
    public let sessionTitle: String?
    public let selectionMode: SessionSelectionMode
    public let stage: TaskStage
    public let updatedAt: Date?
    public let dynamicIconEnabled: Bool

    public init(
        visibility: PulseVisibility,
        weeklyRemainingPercent: Double? = nil,
        weeklyResetsAt: Date? = nil,
        tokenSpeed: TokenSpeed = .unavailable,
        model: String? = nil,
        contextAvailablePercent: Double? = nil,
        contextUsedTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        sessionID: String? = nil,
        sessionTitle: String? = nil,
        selectionMode: SessionSelectionMode = .automatic,
        stage: TaskStage = .idle,
        updatedAt: Date? = nil,
        dynamicIconEnabled: Bool = false
    ) {
        self.visibility = visibility
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.tokenSpeed = tokenSpeed
        self.model = model
        self.contextAvailablePercent = contextAvailablePercent
        self.contextUsedTokens = contextUsedTokens
        self.contextWindowTokens = contextWindowTokens
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.selectionMode = selectionMode
        self.stage = stage
        self.updatedAt = updatedAt
        self.dynamicIconEnabled = dynamicIconEnabled
    }

    public static let hidden = StatusSnapshot(visibility: .hidden)

    public var menuBarText: String {
        guard visibility != .hidden else { return "" }
        let weekly = weeklyRemainingPercent.map { "W \(Int($0.rounded()))%" } ?? "W —"
        guard visibility == .active else { return weekly }
        return [
            weekly,
            tokenSpeed.compactText,
            ModelName.short(model),
            contextAvailablePercent.map { "Ctx \(Int($0.rounded()))%" } ?? "Ctx —"
        ].joined(separator: " · ")
    }
}

public enum ModelName {
    public static func short(_ identifier: String?) -> String {
        guard let identifier, !identifier.isEmpty else { return "—" }
        let lower = identifier.lowercased()
        if lower.hasPrefix("gpt-") {
            let components = identifier.split(separator: "-")
            if components.count >= 2 {
                return "GPT‑\(components[1])"
            }
        }
        return identifier
    }
}
