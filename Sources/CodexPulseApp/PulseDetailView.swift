import SwiftUI
import CodexPulseCore

@MainActor
final class PulseDetailViewModel: ObservableObject {
    @Published var presentation: PulseViewState = .hidden
    var actions = StatusBarActions()
    var onHoverChanged: @MainActor @Sendable (Bool) -> Void = { _ in }
}

@MainActor
struct PulseDetailView: View {
    @ObservedObject var model: PulseDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            metrics
            Divider()
            sessionSection
            Divider()
            settings
        }
        .padding(16)
        .frame(width: 330)
        .onHover(perform: model.onHoverChanged)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Codex Pulse")
                .font(.headline)
            Spacer()
            Text(model.presentation.detail.stage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var metrics: some View {
        VStack(spacing: 9) {
            ForEach(model.presentation.detail.metrics) { metric in
                metricRow(
                    metric.label,
                    metric.value,
                    valueColor: metric.usesWeeklyColor ? weeklySwiftUIColor : nil
                )
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前会话")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.presentation.detail.sessionTitle)
                .font(.callout)
                .lineLimit(2)
            Menu(model.presentation.detail.selectionLabel) {
                Button("自动跟随") { model.actions.pinSession(nil) }
                Divider()
                ForEach(model.presentation.detail.sessions) { session in
                    Button(session.isActive ? "● \(session.title)" : session.title) {
                        model.actions.pinSession(session.id)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            if model.presentation.detail.pinnedSessionUnavailable {
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
                    get: { model.presentation.dynamicIconEnabled },
                    set: { model.actions.toggleDynamicIcon($0) }
                )
            )
            Toggle(
                "随 Codex 启动",
                isOn: Binding(
                    get: { model.presentation.launchWithCodex },
                    set: { model.actions.toggleLaunchWithCodex($0) }
                )
            )
            if let message = model.presentation.launchStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("选择 CODEX_HOME…", action: model.actions.chooseCodexHome)
                Spacer()
                Button("退出插件", action: model.actions.quit)
            }
            Text("CODEX_HOME: \(model.presentation.codexHomePath)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.switch)
    }

    private var weeklySwiftUIColor: Color {
        guard let rgb = model.presentation.weeklyColor else { return .secondary }
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
}
