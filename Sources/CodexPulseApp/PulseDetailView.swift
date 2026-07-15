import SwiftUI
import CodexPulseCore

@MainActor
struct PulseDetailView: View {
    let snapshot: StatusSnapshot
    let sessions: [SessionSummary]
    let preferences: PulsePreferences
    let onDynamicIconChanged: @MainActor @Sendable (Bool) -> Void
    let onLaunchWithCodexChanged: @MainActor @Sendable (Bool) -> Void
    let onPinSession: @MainActor @Sendable (String?) -> Void
    let onChooseCodexHome: @MainActor @Sendable () -> Void
    let onQuit: @MainActor @Sendable () -> Void
    let onHoverChanged: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            metrics
            if snapshot.visibility == .active || snapshot.selectionMode != .automatic {
                Divider()
                sessionSection
            }
            Divider()
            settings
        }
        .padding(16)
        .frame(width: 330)
        .onHover(perform: onHoverChanged)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Codex Pulse")
                .font(.headline)
            Spacer()
            Text(snapshot.stage.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var metrics: some View {
        VStack(spacing: 9) {
            metricRow(
                "Weekly",
                snapshot.weeklyRemainingPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                valueColor: weeklySwiftUIColor
            )
            metricRow("重置", formatted(snapshot.weeklyResetsAt))
            if snapshot.visibility == .active {
                metricRow("Token 速度", snapshot.tokenSpeed.compactText)
                metricRow(
                    "近 5 次平均",
                    snapshot.tokenSpeed.recentAverage.map { String(format: "%.1f t/s", $0) } ?? "—"
                )
                metricRow("模型", snapshot.model ?? "—")
                metricRow(
                    "上下文可用",
                    snapshot.contextAvailablePercent.map { String(format: "%.1f%%", $0) } ?? "—"
                )
                if let used = snapshot.contextUsedTokens, let window = snapshot.contextWindowTokens {
                    metricRow("上下文 Token", "\(used) / \(window)")
                }
            }
            metricRow("更新", relative(snapshot.updatedAt))
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前会话")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(snapshot.sessionTitle ?? snapshot.sessionID ?? "—")
                .font(.callout)
                .lineLimit(2)
            Menu(selectionLabel) {
                Button("自动跟随") { onPinSession(nil) }
                Divider()
                ForEach(sessions.prefix(16)) { session in
                    Button(session.isActive ? "● \(session.title)" : session.title) {
                        onPinSession(session.id)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            if snapshot.selectionMode == .pinnedUnavailable {
                Text("固定会话不可用；未切换到其他任务。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "动态图标显示",
                isOn: Binding(
                    get: { preferences.dynamicIconEnabled },
                    set: { onDynamicIconChanged($0) }
                )
            )
            Toggle(
                "随 Codex 启动",
                isOn: Binding(
                    get: { preferences.launchWithCodex },
                    set: { onLaunchWithCodexChanged($0) }
                )
            )
            HStack {
                Button("选择 CODEX_HOME…", action: onChooseCodexHome)
                Spacer()
                Button("退出插件", action: onQuit)
            }
        }
        .toggleStyle(.switch)
    }

    private var selectionLabel: String {
        switch snapshot.selectionMode {
        case .automatic: "自动跟随"
        case .pinned: "固定会话"
        case .pinnedUnavailable: "固定会话不可用"
        }
    }

    private var weeklySwiftUIColor: Color {
        let rgb = WeeklyColor.color(remainingPercent: snapshot.weeklyRemainingPercent ?? 0)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func metricRow(_ label: String, _ value: String, valueColor: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(valueColor ?? .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
