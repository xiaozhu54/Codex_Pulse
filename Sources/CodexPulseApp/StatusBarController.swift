import AppKit
import SwiftUI
import CodexPulseCore

@MainActor
struct StatusBarActions {
    var toggleDynamicIcon: @MainActor @Sendable (Bool) -> Void = { _ in }
    var toggleLaunchWithCodex: @MainActor @Sendable (Bool) -> Void = { _ in }
    var pinSession: @MainActor @Sendable (String?) -> Void = { _ in }
    var restoreAutomatic: @MainActor @Sendable () -> Void = {}
    var chooseCodexHome: @MainActor @Sendable () -> Void = {}
    var quit: @MainActor @Sendable () -> Void = {}
}

@MainActor
final class StatusBarController: NSObject {
    var actions = StatusBarActions()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hoverTracker: HoverTrackingView?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private var hoverCloseWorkItem: DispatchWorkItem?
    private var isPopoverPinned = false
    private var isPopoverHovered = false
    private var snapshot = StatusSnapshot.hidden
    private var sessions: [SessionSummary] = []
    private var preferences = PulsePreferences()

    override init() {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = true
    }

    func show() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusButtonPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Codex Pulse"

        let tracker = HoverTrackingView(frame: button.bounds)
        tracker.autoresizingMask = [.width, .height]
        tracker.onEntered = { [weak self] in self?.scheduleHoverOpen() }
        tracker.onExited = { [weak self] in self?.scheduleHoverClose() }
        button.addSubview(tracker)
        hoverTracker = tracker
        statusItem = item
    }

    func hide() {
        hoverOpenWorkItem?.cancel()
        hoverCloseWorkItem?.cancel()
        popover.performClose(nil)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        hoverTracker = nil
        isPopoverPinned = false
    }

    func render(snapshot: StatusSnapshot, sessions: [SessionSummary], preferences: PulsePreferences) {
        self.snapshot = snapshot
        self.sessions = sessions
        self.preferences = preferences
        guard snapshot.visibility != .hidden else {
            hide()
            return
        }
        show()
        guard let item = statusItem, let button = item.button else { return }

        if preferences.dynamicIconEnabled {
            item.length = NSStatusItem.squareLength
            button.attributedTitle = NSAttributedString(string: "")
            button.image = coloredIcon()
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Codex Pulse，Weekly \(weeklyAccessibilityValue)")
        } else {
            item.length = NSStatusItem.variableLength
            button.image = nil
            button.attributedTitle = attributedMenuTitle(snapshot.menuBarText)
            button.imagePosition = .noImage
            button.setAccessibilityLabel("Codex Pulse，\(snapshot.menuBarText)")
        }
        updatePopoverContent()
    }

    @objc private func statusButtonPressed(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettingsMenu()
            return
        }
        if popover.isShown && isPopoverPinned {
            isPopoverPinned = false
            popover.performClose(nil)
        } else {
            isPopoverPinned = true
            showPopover()
        }
    }

    private func scheduleHoverOpen() {
        hoverCloseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isPopoverPinned else { return }
            self.showPopover()
        }
        hoverOpenWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func scheduleHoverClose() {
        hoverOpenWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isPopoverPinned, !self.isPopoverHovered else { return }
            self.popover.performClose(nil)
        }
        hoverCloseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        updatePopoverContent()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updatePopoverContent() {
        popover.contentViewController = NSHostingController(rootView: PulseDetailView(
            snapshot: snapshot,
            sessions: sessions,
            preferences: preferences,
            onDynamicIconChanged: actions.toggleDynamicIcon,
            onLaunchWithCodexChanged: actions.toggleLaunchWithCodex,
            onPinSession: actions.pinSession,
            onChooseCodexHome: actions.chooseCodexHome,
            onQuit: actions.quit,
            onHoverChanged: { [weak self] hovering in
                self?.isPopoverHovered = hovering
                if !hovering { self?.scheduleHoverClose() }
                else { self?.hoverCloseWorkItem?.cancel() }
            }
        ))
    }

    private func showSettingsMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let dynamic = NSMenuItem(
            title: "动态图标显示",
            action: #selector(toggleDynamicFromMenu(_:)),
            keyEquivalent: ""
        )
        dynamic.target = self
        dynamic.state = preferences.dynamicIconEnabled ? .on : .off
        menu.addItem(dynamic)

        let launch = NSMenuItem(
            title: "随 Codex 启动",
            action: #selector(toggleLaunchFromMenu(_:)),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = preferences.launchWithCodex ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())

        let choose = NSMenuItem(
            title: "选择 CODEX_HOME…",
            action: #selector(chooseCodexHomeFromMenu(_:)),
            keyEquivalent: ""
        )
        choose.target = self
        menu.addItem(choose)

        if preferences.pinnedSessionID != nil {
            let restore = NSMenuItem(
                title: "恢复自动跟随",
                action: #selector(restoreAutomaticFromMenu(_:)),
                keyEquivalent: ""
            )
            restore.target = self
            menu.addItem(restore)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出插件", action: #selector(quitFromMenu(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
    }

    @objc private func toggleDynamicFromMenu(_ sender: NSMenuItem) {
        actions.toggleDynamicIcon(!preferences.dynamicIconEnabled)
    }

    @objc private func toggleLaunchFromMenu(_ sender: NSMenuItem) {
        actions.toggleLaunchWithCodex(!preferences.launchWithCodex)
    }

    @objc private func chooseCodexHomeFromMenu(_ sender: NSMenuItem) { actions.chooseCodexHome() }
    @objc private func restoreAutomaticFromMenu(_ sender: NSMenuItem) { actions.restoreAutomatic() }
    @objc private func quitFromMenu(_ sender: NSMenuItem) { actions.quit() }

    private var weeklyAccessibilityValue: String {
        snapshot.weeklyRemainingPercent.map { "\(Int($0.rounded()))%" } ?? "不可用"
    }

    private func attributedMenuTitle(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttributes([
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ], range: whole)

        let weeklyLength: Int
        let nsText = text as NSString
        let separator = nsText.range(of: " · ")
        weeklyLength = separator.location == NSNotFound ? nsText.length : separator.location
        let rgb = WeeklyColor.color(remainingPercent: snapshot.weeklyRemainingPercent ?? 0)
        let color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = .zero
        result.addAttributes([
            .foregroundColor: color,
            .shadow: shadow
        ], range: NSRange(location: 0, length: weeklyLength))
        return result
    }

    private func coloredIcon() -> NSImage {
        let percent = snapshot.weeklyRemainingPercent ?? 0
        let rgb = WeeklyColor.color(remainingPercent: percent)
        let color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        let source = sourceIcon()
        let size = NSSize(width: 18, height: 18)
        let outline = mask(source: source, color: NSColor.black.withAlphaComponent(0.5), size: size)
        let foreground = mask(source: source, color: color, size: size)
        let image = NSImage(size: size)
        image.lockFocus()
        for offset in [NSPoint(x: -0.5, y: 0), NSPoint(x: 0.5, y: 0), NSPoint(x: 0, y: -0.5), NSPoint(x: 0, y: 0.5)] {
            outline.draw(at: offset, from: .zero, operation: .sourceOver, fraction: 0.55)
        }
        foreground.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func sourceIcon() -> NSImage {
        if let url = Bundle.main.url(forResource: "weekly-codex-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 52, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        NSAttributedString(string: "W", attributes: attributes)
            .draw(at: NSPoint(x: 3, y: 2))
        image.unlockFocus()
        return image
    }

    private func mask(source: NSImage, color: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        source.draw(
            in: NSRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2),
            from: .zero,
            operation: .destinationIn,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }
}

@MainActor
private final class HoverTrackingView: NSView {
    var onEntered: () -> Void = {}
    var onExited: () -> Void = {}
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onEntered() }
    override func mouseExited(with event: NSEvent) { onExited() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
