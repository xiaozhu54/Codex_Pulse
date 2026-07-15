public enum MenuBarMode: Equatable, Sendable {
    case hidden
    case text
    case icon
}

public struct MenuBarPresentation: Equatable, Sendable {
    public let mode: MenuBarMode
    public let text: String
    public let weeklyColor: PulseRGBColor?

    public init(snapshot: StatusSnapshot, preferences: PulsePreferences) {
        if snapshot.visibility == .hidden { mode = .hidden }
        else { mode = preferences.dynamicIconEnabled ? .icon : .text }
        text = snapshot.menuBarText
        weeklyColor = snapshot.weeklyRemainingPercent.map(WeeklyColor.color)
    }
}
