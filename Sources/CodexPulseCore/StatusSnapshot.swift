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

}

public struct TokenSpeed: Equatable, Sendable {
    public enum OutputKind: Equatable, Sendable {
        case text
        case toolCall
    }

    public enum Kind: Equatable, Sendable {
        case estimating
        case final
        case thinking
        case unavailable
    }

    public let kind: Kind
    public let tokensPerSecond: Double?
    public let recentAverage: Double?
    public let outputKind: OutputKind?

    public init(
        kind: Kind,
        tokensPerSecond: Double? = nil,
        recentAverage: Double? = nil,
        outputKind: OutputKind? = nil
    ) {
        self.kind = kind
        self.tokensPerSecond = tokensPerSecond
        self.recentAverage = recentAverage
        self.outputKind = outputKind
    }

    public static let unavailable = TokenSpeed(kind: .unavailable)

}

public enum MetricAvailability: String, Equatable, Sendable {
    case available
    case stale
    case unavailable
}

public enum MetricSource: String, Equatable, Sendable {
    case sessionJournal
    case threadIndex
    case responseLog
    case derived
}

public enum SourceIssue: String, Equatable, Sendable {
    case missing
    case incompatible
    case busy
    case readFailed
    case rotated
}

public struct MetricValue<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value?
    public let availability: MetricAvailability
    public let observedAt: Date?
    public let source: MetricSource?
    public let issue: SourceIssue?

    public init(
        value: Value?,
        availability: MetricAvailability? = nil,
        observedAt: Date? = nil,
        source: MetricSource? = nil,
        issue: SourceIssue? = nil
    ) {
        self.value = value
        self.availability = availability ?? (value == nil ? .unavailable : .available)
        self.observedAt = observedAt
        self.source = source
        self.issue = issue
    }

    public static var unavailable: Self { Self(value: nil) }
}

public extension MetricValue where Value == TokenSpeed {
    var kind: TokenSpeed.Kind { value?.kind ?? .unavailable }
    var tokensPerSecond: Double? { value?.tokensPerSecond }
    var recentAverage: Double? { value?.recentAverage }
}

public enum LaunchMonitorStatus: String, Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
    case failed
    case unknown
}

public struct SourceStatus: Equatable, Sendable {
    public let availability: MetricAvailability
    public let observedAt: Date?
    public let issue: SourceIssue?

    public init(
        availability: MetricAvailability,
        observedAt: Date? = nil,
        issue: SourceIssue? = nil
    ) {
        self.availability = availability
        self.observedAt = observedAt
        self.issue = issue
    }

    public static let available = SourceStatus(availability: .available)
    public static let unavailable = SourceStatus(availability: .unavailable)
}

public struct SourceHealth: Equatable, Sendable {
    public let sessionJournal: SourceStatus
    public let threadIndex: SourceStatus
    public let responseLog: SourceStatus

    public init(sessionJournal: SourceStatus, threadIndex: SourceStatus, responseLog: SourceStatus) {
        self.sessionJournal = sessionJournal
        self.threadIndex = threadIndex
        self.responseLog = responseLog
    }

    public static let allAvailable = SourceHealth(
        sessionJournal: .available,
        threadIndex: .available,
        responseLog: .available
    )

    public static let unavailable = SourceHealth(
        sessionJournal: .unavailable,
        threadIndex: .unavailable,
        responseLog: .unavailable
    )
}

public struct StatusSnapshot: Equatable, Sendable {
    public let visibility: PulseVisibility
    public let weekly: MetricValue<Double>
    public let weeklyResetsAt: MetricValue<Date>
    public let tokenSpeed: MetricValue<TokenSpeed>
    public let model: MetricValue<String>
    public let contextAvailable: MetricValue<Double>
    public let contextUsedTokens: Int?
    public let contextWindowTokens: Int?
    public let sessionID: String?
    public let sessionTitle: String?
    public let selectionMode: SessionSelectionMode
    public let stage: TaskStage
    public let updatedAt: Date?

    public init(
        visibility: PulseVisibility,
        weekly: MetricValue<Double> = .unavailable,
        weeklyResetsAt: MetricValue<Date> = .unavailable,
        tokenSpeed: MetricValue<TokenSpeed> = .unavailable,
        model: MetricValue<String> = .unavailable,
        contextAvailable: MetricValue<Double> = .unavailable,
        contextUsedTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        sessionID: String? = nil,
        sessionTitle: String? = nil,
        selectionMode: SessionSelectionMode = .automatic,
        stage: TaskStage = .idle,
        updatedAt: Date? = nil
    ) {
        self.visibility = visibility
        self.weekly = weekly
        self.weeklyResetsAt = weeklyResetsAt
        self.tokenSpeed = tokenSpeed
        self.model = model
        self.contextAvailable = contextAvailable
        self.contextUsedTokens = contextUsedTokens
        self.contextWindowTokens = contextWindowTokens
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.selectionMode = selectionMode
        self.stage = stage
        self.updatedAt = updatedAt
    }

    public static let hidden = StatusSnapshot(visibility: .hidden)

    public var weeklyRemainingPercent: Double? { weekly.value }
    public var weeklyResetDate: Date? { weeklyResetsAt.value }
    public var contextAvailablePercent: Double? { contextAvailable.value }
}

public struct PulseState: Equatable, Sendable {
    public let snapshot: StatusSnapshot
    public let sessions: [SessionSummary]
    public let sourceHealth: SourceHealth

    public init(snapshot: StatusSnapshot, sessions: [SessionSummary], sourceHealth: SourceHealth) {
        self.snapshot = snapshot
        self.sessions = sessions
        self.sourceHealth = sourceHealth
    }

    public static let hidden = PulseState(snapshot: .hidden, sessions: [], sourceHealth: .unavailable)
}

public struct PulseRefreshRequest: Equatable, Sendable {
    public let codexRunning: Bool
    public let pinnedSessionID: String?
    public let now: Date

    public init(codexRunning: Bool, pinnedSessionID: String?, now: Date = Date()) {
        self.codexRunning = codexRunning
        self.pinnedSessionID = pinnedSessionID
        self.now = now
    }
}
