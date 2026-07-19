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
    static let autosaveName = "com.origami.codexpulse.status-item"

    var actions = StatusBarActions() {
        didSet { detailModel.actions = actions }
    }

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var hoverTracker: HoverTrackingOwner?
    private var hoverOpenWorkItem: DispatchWorkItem?
    private var hoverCloseWorkItem: DispatchWorkItem?
    private var isPopoverPinned = false
    private var isPopoverHovered = false
    private var presentation = PulseViewState.hidden
    private let detailModel = PulseDetailViewModel()
    private var renderedDynamicIconEnabled: Bool?
    private var renderedMenuBarText: String?
    private var renderedWeeklyPercent: Double?
    private var didGuideForBlockedStatusItem = false

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        detailModel.onHoverChanged = { [weak self] hovering in
            self?.isPopoverHovered = hovering
            if hovering { self?.hoverCloseWorkItem?.cancel() }
            else { self?.scheduleHoverClose() }
        }
        popover.contentViewController = NSHostingController(rootView: PulseDetailView(model: detailModel))
    }

    func show() {
        if let statusItem {
            // A status item can become invisible after an interrupted Command-drag.
            // It is not user-removable, so restore it instead of leaving the app
            // running without any way to reach its controls.
            if !statusItem.isVisible { statusItem.isVisible = true }
            return
        }
        StatusItemPlacementPreflight.repairIfNeeded(autosaveName: Self.autosaveName)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.behavior = []
        item.isVisible = true
        guard let button = item.button else { return }
        button.title = "W —"
        button.imagePosition = .noImage
        button.target = self
        button.action = #selector(statusButtonPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Codex Pulse"

        let tracker = HoverTrackingOwner()
        tracker.onEntered = { [weak self] in self?.scheduleHoverOpen() }
        tracker.onExited = { [weak self] in self?.scheduleHoverClose() }
        tracker.install(on: button)
        hoverTracker = tracker
        statusItem = item
    }

    func hide() {
        hoverOpenWorkItem?.cancel()
        hoverCloseWorkItem?.cancel()
        popover.performClose(nil)
        hoverTracker?.uninstall()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        hoverTracker = nil
        isPopoverPinned = false
        renderedDynamicIconEnabled = nil
        renderedMenuBarText = nil
        renderedWeeklyPercent = nil
    }

    func health() -> StatusItemHealth {
        guard let statusItem else {
            return StatusItemHealth(
                isVisible: false,
                hasButton: false,
                hasWindow: false,
                hasScreen: false,
                width: 0
            )
        }
        let button = statusItem.button
        return StatusItemHealth(
            isVisible: statusItem.isVisible,
            hasButton: button != nil,
            hasWindow: button?.window != nil,
            hasScreen: button?.window?.screen != nil,
            width: Double(button?.bounds.width ?? 0)
        )
    }

    func recover(_ action: StatusItemRecoveryAction) {
        switch action {
        case .none:
            didGuideForBlockedStatusItem = false
        case .refresh:
            statusItem?.isVisible = true
            statusItem?.button?.needsDisplay = true
        case .rebuild:
            guard presentation.mode != .hidden else { return }
            hide()
            show()
            applyPresentation()
        case .guideUser:
            guard !didGuideForBlockedStatusItem else { return }
            didGuideForBlockedStatusItem = true
            let alert = NSAlert()
            alert.messageText = "Codex Pulse 菜单栏图标被系统隐藏"
            alert.informativeText = "请在系统设置的菜单栏管理中允许 Codex Pulse 显示。应用会继续在本地运行。"
            alert.addButton(withTitle: "打开菜单栏设置")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func render(_ presentation: PulseViewState) {
        self.presentation = presentation
        detailModel.presentation = presentation
        detailModel.actions = actions
        guard presentation.mode != .hidden else {
            hide()
            return
        }
        show()
        applyPresentation()
    }

    private func applyPresentation() {
        guard let item = statusItem, let button = item.button else { return }

        // AppKit owns the status item while Command-dragging it. Changing its
        // length or contents during that gesture can cancel the move and leave
        // the item hidden. The next 500 ms refresh applies the latest snapshot.
        guard !NSEvent.modifierFlags.contains(.command) else {
            if popover.isShown { updatePopoverContent() }
            return
        }

        if presentation.mode == .icon {
            if renderedDynamicIconEnabled != true ||
                renderedWeeklyPercent != presentation.weeklyPercent {
                item.length = NSStatusItem.squareLength
                button.attributedTitle = NSAttributedString(string: "")
                button.image = coloredIcon()
                button.alternateImage = highContrastIcon()
                button.imagePosition = .imageOnly
            }
            button.setAccessibilityLabel(presentation.accessibilityLabel)
        } else {
            if renderedDynamicIconEnabled != false ||
                renderedMenuBarText != presentation.menuBarText ||
                renderedWeeklyPercent != presentation.weeklyPercent {
                item.length = NSStatusItem.variableLength
                button.image = nil
                button.alternateImage = nil
                button.attributedTitle = attributedMenuTitle(presentation.menuBarSegments)
                button.attributedAlternateTitle = attributedMenuTitle(
                    presentation.menuBarSegments,
                    selected: true
                )
                button.imagePosition = .noImage
            }
            button.setAccessibilityLabel(presentation.accessibilityLabel)
        }
        renderedDynamicIconEnabled = presentation.mode == .icon
        renderedMenuBarText = presentation.menuBarText
        renderedWeeklyPercent = presentation.weeklyPercent
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
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        updatePopoverContent()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updatePopoverContent() {
        detailModel.presentation = presentation
        detailModel.actions = actions
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
        dynamic.state = presentation.dynamicIconEnabled ? .on : .off
        menu.addItem(dynamic)

        let launch = NSMenuItem(
            title: "随 Codex 启动",
            action: #selector(toggleLaunchFromMenu(_:)),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = presentation.launchWithCodex ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())

        let choose = NSMenuItem(
            title: "选择 CODEX_HOME…",
            action: #selector(chooseCodexHomeFromMenu(_:)),
            keyEquivalent: ""
        )
        choose.target = self
        menu.addItem(choose)

        if presentation.pinnedSessionID != nil {
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
        actions.toggleDynamicIcon(!presentation.dynamicIconEnabled)
    }

    @objc private func toggleLaunchFromMenu(_ sender: NSMenuItem) {
        actions.toggleLaunchWithCodex(!presentation.launchWithCodex)
    }

    @objc private func chooseCodexHomeFromMenu(_ sender: NSMenuItem) { actions.chooseCodexHome() }
    @objc private func restoreAutomaticFromMenu(_ sender: NSMenuItem) { actions.restoreAutomatic() }
    @objc private func quitFromMenu(_ sender: NSMenuItem) { actions.quit() }

    private func attributedMenuTitle(
        _ segments: [PulseMenuBarSegment],
        selected: Bool = false
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let color = presentation.weeklyColor.map {
            NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
        } ?? .secondaryLabelColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = .zero
        for segment in segments {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: selected ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
            ]
            if segment.usesWeeklyColor && !selected {
                attributes[.foregroundColor] = color
                attributes[.shadow] = shadow
            }
            result.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return result
    }

    private func coloredIcon() -> NSImage {
        let color = presentation.weeklyColor.map {
            NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
        } ?? .secondaryLabelColor
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

    private func highContrastIcon() -> NSImage {
        let image = mask(
            source: sourceIcon(),
            color: .selectedMenuItemTextColor,
            size: NSSize(width: 18, height: 18)
        )
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

extension StatusBarController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        isPopoverPinned = false
        isPopoverHovered = false
    }
}

@MainActor
private final class HoverTrackingOwner: NSResponder {
    var onEntered: () -> Void = {}
    var onExited: () -> Void = {}
    private weak var view: NSView?
    private var tracking: NSTrackingArea?

    func install(on view: NSView) {
        uninstall()
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        self.view = view
        tracking = area
    }

    func uninstall() {
        if let tracking, let view { view.removeTrackingArea(tracking) }
        tracking = nil
        view = nil
    }

    override func mouseEntered(with event: NSEvent) { onEntered() }
    override func mouseExited(with event: NSEvent) { onExited() }
}
