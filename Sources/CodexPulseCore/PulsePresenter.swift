import Foundation

public enum MenuBarMode: Equatable, Sendable {
    case hidden
    case text
    case icon
}

public struct PulseMenuBarSegment: Equatable, Sendable {
    public let text: String
    public let usesWeeklyColor: Bool

    public init(text: String, usesWeeklyColor: Bool = false) {
        self.text = text
        self.usesWeeklyColor = usesWeeklyColor
    }
}

public struct PulseMetricPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let value: String
    public let usesWeeklyColor: Bool

    public init(id: String, label: String, value: String, usesWeeklyColor: Bool = false) {
        self.id = id
        self.label = label
        self.value = value
        self.usesWeeklyColor = usesWeeklyColor
    }
}

public struct PulseDetailPresentation: Equatable, Sendable {
    public let stage: String
    public let metrics: [PulseMetricPresentation]
    public let sessionTitle: String
    public let selectionLabel: String
    public let pinnedSessionUnavailable: Bool
    public let sessions: [SessionSummary]

    public init(
        stage: String,
        metrics: [PulseMetricPresentation],
        sessionTitle: String,
        selectionLabel: String,
        pinnedSessionUnavailable: Bool,
        sessions: [SessionSummary]
    ) {
        self.stage = stage
        self.metrics = metrics
        self.sessionTitle = sessionTitle
        self.selectionLabel = selectionLabel
        self.pinnedSessionUnavailable = pinnedSessionUnavailable
        self.sessions = sessions
    }
}

public struct PulseViewState: Equatable, Sendable {
    public let mode: MenuBarMode
    public let menuBarText: String
    public let menuBarSegments: [PulseMenuBarSegment]
    public let weeklyColor: PulseRGBColor?
    public let weeklyPercent: Double?
    public let accessibilityLabel: String
    public let detail: PulseDetailPresentation
    public let dynamicIconEnabled: Bool
    public let launchWithCodex: Bool
    public let launchStatusMessage: String?
    public let pinnedSessionID: String?
    public let codexHomePath: String

    public init(
        mode: MenuBarMode,
        menuBarText: String,
        menuBarSegments: [PulseMenuBarSegment],
        weeklyColor: PulseRGBColor?,
        weeklyPercent: Double?,
        accessibilityLabel: String,
        detail: PulseDetailPresentation,
        dynamicIconEnabled: Bool,
        launchWithCodex: Bool,
        launchStatusMessage: String?,
        pinnedSessionID: String?,
        codexHomePath: String
    ) {
        self.mode = mode
        self.menuBarText = menuBarText
        self.menuBarSegments = menuBarSegments
        self.weeklyColor = weeklyColor
        self.weeklyPercent = weeklyPercent
        self.accessibilityLabel = accessibilityLabel
        self.detail = detail
        self.dynamicIconEnabled = dynamicIconEnabled
        self.launchWithCodex = launchWithCodex
        self.launchStatusMessage = launchStatusMessage
        self.pinnedSessionID = pinnedSessionID
        self.codexHomePath = codexHomePath
    }

    public static let hidden = PulsePresenter.present(state: .hidden, preferences: PulsePreferences())
}

public enum PulsePresenter {
    public static func present(
        state: PulseState,
        preferences: PulsePreferences,
        now: Date = Date(),
        codexHomePath: String = "~/.codex",
        launchMonitorStatus: LaunchMonitorStatus = .unknown
    ) -> PulseViewState {
        let snapshot = state.snapshot
        let segments = summarySegments(snapshot)
        let summary = segments.map(\.text).joined()
        let mode: MenuBarMode
        if snapshot.visibility == .hidden { mode = .hidden }
        else { mode = preferences.dynamicIconEnabled ? .icon : .text }

        let weekly = visible(snapshot.weekly)
        let weeklyText = weekly.map { "\(Int($0.rounded()))%" } ?? "—"
        let activeDetails = segments.dropFirst().map(\.text).joined()
        let accessibility = snapshot.visibility == .hidden
            ? "Codex Pulse 已隐藏"
            : "Codex Pulse，Weekly \(weeklyText)\(activeDetails)"
        let launch = launchPresentation(status: launchMonitorStatus, fallback: preferences.launchWithCodex)

        return PulseViewState(
            mode: mode,
            menuBarText: mode == .text ? summary : "",
            menuBarSegments: mode == .text ? segments : [],
            weeklyColor: weekly.map(WeeklyColor.color),
            weeklyPercent: weekly,
            accessibilityLabel: accessibility,
            detail: detail(snapshot: snapshot, sessions: state.sessions, health: state.sourceHealth, now: now),
            dynamicIconEnabled: preferences.dynamicIconEnabled,
            launchWithCodex: launch.enabled,
            launchStatusMessage: launch.message,
            pinnedSessionID: preferences.pinnedSessionID,
            codexHomePath: codexHomePath
        )
    }

    private static func summarySegments(_ snapshot: StatusSnapshot) -> [PulseMenuBarSegment] {
        guard snapshot.visibility != .hidden else { return [] }
        let weekly = visible(snapshot.weekly).map { "W \(Int($0.rounded()))%" } ?? "W —"
        var segments = [PulseMenuBarSegment(text: weekly, usesWeeklyColor: true)]
        guard snapshot.visibility == .active else { return segments }
        let values = [
            speedText(visible(snapshot.tokenSpeed)),
            shortModel(visible(snapshot.model)),
            visible(snapshot.contextAvailable).map { "Ctx \(Int($0.rounded()))%" } ?? "Ctx —"
        ]
        for value in values {
            segments.append(PulseMenuBarSegment(text: " · "))
            segments.append(PulseMenuBarSegment(text: value))
        }
        return segments
    }

    private static func detail(
        snapshot: StatusSnapshot,
        sessions: [SessionSummary],
        health: SourceHealth,
        now: Date
    ) -> PulseDetailPresentation {
        var metrics = [
            PulseMetricPresentation(
                id: "weekly",
                label: "Weekly",
                value: visible(snapshot.weekly).map { String(format: "%.1f%%", $0) } ?? "—",
                usesWeeklyColor: true
            ),
            PulseMetricPresentation(
                id: "reset",
                label: "重置",
                value: format(visible(snapshot.weeklyResetsAt))
            )
        ]
        if snapshot.visibility == .active {
            let speed = visible(snapshot.tokenSpeed)
            metrics.append(contentsOf: [
                PulseMetricPresentation(id: "speed", label: "Token 速度", value: speedText(speed)),
                PulseMetricPresentation(
                    id: "average",
                    label: "近 5 次平均",
                    value: speed?.recentAverage.map { String(format: "%.1f t/s", $0) } ?? "—"
                ),
                PulseMetricPresentation(id: "model", label: "模型", value: visible(snapshot.model) ?? "—"),
                PulseMetricPresentation(
                    id: "context",
                    label: "上下文可用",
                    value: visible(snapshot.contextAvailable).map { String(format: "%.1f%%", $0) } ?? "—"
                )
            ])
            if visible(snapshot.contextAvailable) != nil,
               let used = snapshot.contextUsedTokens,
               let window = snapshot.contextWindowTokens {
                metrics.append(PulseMetricPresentation(
                    id: "contextTokens",
                    label: "上下文 Token",
                    value: "\(used) / \(window)"
                ))
            }
        }
        metrics.append(PulseMetricPresentation(
            id: "updated",
            label: "更新",
            value: relative(snapshot.updatedAt, now: now)
        ))
        metrics.append(contentsOf: sourceHealthMetrics(health))

        return PulseDetailPresentation(
            stage: stageName(snapshot.stage),
            metrics: metrics,
            sessionTitle: snapshot.sessionTitle ?? snapshot.sessionID ?? "—",
            selectionLabel: selectionLabel(snapshot.selectionMode),
            pinnedSessionUnavailable: snapshot.selectionMode == .pinnedUnavailable,
            sessions: Array(sessions.prefix(16))
        )
    }

    private static func sourceHealthMetrics(_ health: SourceHealth) -> [PulseMetricPresentation] {
        [
            ("source-session", "会话数据", health.sessionJournal),
            ("source-index", "线程索引", health.threadIndex),
            ("source-response", "响应日志", health.responseLog)
        ].compactMap { id, label, status in
            guard status.availability != .available else { return nil }
            return PulseMetricPresentation(id: id, label: label, value: sourceStatusText(status))
        }
    }

    private static func sourceStatusText(_ status: SourceStatus) -> String {
        let availability = status.availability == .stale ? "过期" : "不可用"
        let issue: String?
        switch status.issue {
        case .missing: issue = "缺失"
        case .incompatible: issue = "格式不兼容"
        case .busy: issue = "暂时繁忙"
        case .readFailed: issue = "读取失败"
        case .rotated: issue = "文件已轮转"
        case nil: issue = nil
        }
        return issue.map { "\(availability)（\($0)）" } ?? availability
    }

    private static func launchPresentation(
        status: LaunchMonitorStatus,
        fallback: Bool
    ) -> (enabled: Bool, message: String?) {
        switch status {
        case .enabled: (true, nil)
        case .disabled: (false, nil)
        case .requiresApproval: (true, "需在系统设置中允许后台项目")
        case .unavailable: (fallback, "当前应用包中没有可用的启动监视器")
        case .failed: (fallback, "无法读取或更新启动监视器状态")
        case .unknown: (fallback, nil)
        }
    }

    private static func visible<Value>(_ metric: MetricValue<Value>) -> Value?
    where Value: Equatable & Sendable {
        metric.availability == .available ? metric.value : nil
    }

    private static func speedText(_ speed: TokenSpeed?) -> String {
        guard let speed else { return "— t/s" }
        switch speed.kind {
        case .estimating:
            return speed.tokensPerSecond.map { String(format: "≈%.1f t/s", $0) } ?? "— t/s"
        case .final:
            return speed.tokensPerSecond.map { String(format: "%.1f t/s", $0) } ?? "— t/s"
        case .thinking:
            return "推理中…"
        case .unavailable:
            return "— t/s"
        }
    }

    private static func shortModel(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "—" }
        switch model.lowercased() {
        case "gpt-5.6", "gpt-5.6-sol": return "GPT‑5.6"
        case "gpt-5.5", "gpt-5.5-sol": return "GPT‑5.5"
        case "gpt-5", "gpt-5-codex": return "GPT‑5"
        default: return model
        }
    }

    private static func stageName(_ stage: TaskStage) -> String {
        switch stage {
        case .idle: "空闲"
        case .thinking: "推理中"
        case .generating: "生成中"
        case .usingTool: "调用工具"
        case .waitingForTool: "等待工具"
        case .waitingForApproval: "等待审批"
        case .finishing: "收尾中"
        case .unavailable: "不可用"
        }
    }

    private static func selectionLabel(_ mode: SessionSelectionMode) -> String {
        switch mode {
        case .automatic: "自动跟随"
        case .pinned: "固定会话"
        case .pinnedUnavailable: "固定会话不可用"
        }
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func relative(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
