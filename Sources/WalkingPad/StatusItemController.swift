import AppKit
import Observation
import SwiftUI

/// The menu bar item and its popup panel.
///
/// Menu bar: click = popup · right/control-click = start/stop belt
///           middle click = connect/disconnect · scroll = faster/slower
/// Popup:    space/s/return = start/stop · ←/→ or -/+ = speed · m = cycle mode
///           c = connect/disconnect · esc = close · ⌘, = settings · ⌘Q = quit
@MainActor
final class StatusItemController: NSObject {
    private let pad: Pad
    private let openSettings: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: MenuBarPanel!
    private var eventMonitors: [Any] = []
    private var outsideClickMonitor: Any?
    private var scrollAccumulator: CGFloat = 0

    init(pad: Pad, openSettings: @escaping () -> Void) {
        self.pad = pad
        self.openSettings = openSettings
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
            button.imagePosition = .imageLeading
        }
        statusItem.autosaveName = "WalkingPad"

        panel = MenuBarPanel(content: PanelView(
            pad: pad,
            openSettings: { [weak self] in self?.close(); openSettings() },
            quit: { NSApp.terminate(nil) },
            onSize: { [weak self] size in self?.resizePanel(to: size) }
        ))
        panel.onResignKey = { [weak self] in self?.close() }

        eventMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, e.window == self.statusItem.button?.window else { return e }
            self.scrolled(e)
            return nil
        } as Any)
        eventMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel, self.handleKey(e) else { return e }
            return nil
        } as Any)

        observe()
        NotificationCenter.default.addObserver(self, selector: #selector(updateButton),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    // MARK: Menu bar button

    private func observe() {
        withObservationTracking {
            updateButton()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    @objc private func updateButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "WalkingPad")
        image?.isTemplate = true
        button.image = image

        var text = ""
        if pad.running {
            switch Settings.barLabel {
            case "steps": text = (pad.status?.steps ?? 0).formatted()
            case "today": text = Format.steps(pad.today.steps)
            case "icon": text = ""
            default: text = Format.speed(pad.displaySpeed)
            }
        }
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .baselineOffset: 0.5,
        ])
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        button.appearsDisabled = !pad.connected
        button.toolTip = isOpen ? nil : "WalkingPad · \(pad.statusText)"
    }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return toggle() }
        switch event.type {
        case .rightMouseUp: pad.toggleBelt()
        case .otherMouseUp: pad.toggleConnection()
        case .leftMouseUp where event.modifierFlags.contains(.control): pad.toggleBelt()
        default: toggle()
        }
    }

    private func scrolled(_ e: NSEvent) {
        guard e.phase != .ended, e.momentumPhase == [] || e.momentumPhase == .began else { return }
        // Scrolling up (or swiping up, whatever the natural-scrolling setting)
        // means faster.
        var dy = e.scrollingDeltaY
        if e.isDirectionInvertedFromDevice { dy = -dy }
        if !e.hasPreciseScrollingDeltas {
            if dy > 0 { pad.faster() } else if dy < 0 { pad.slower() }
            return
        }
        if e.phase == .began { scrollAccumulator = 0 }
        scrollAccumulator += dy
        if abs(scrollAccumulator) >= 24 {
            scrollAccumulator > 0 ? pad.faster() : pad.slower()
            scrollAccumulator = 0
        }
    }

    // MARK: Panel

    var isOpen: Bool { panel.isVisible }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        panel.anchor = NSPoint(x: buttonFrame.minX, y: buttonFrame.minY - 6)
        panel.screenFrame = screen?.visibleFrame ?? .zero
        resizePanel(to: panel.contentSize)
        // Activate like a system menu bar extra, so controls draw in their
        // active colours and the keyboard shortcuts reach the panel.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        updateButton()

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        guard isOpen else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        // Hand focus back to whatever was frontmost, unless Settings is open.
        if NSApp.isActive, !NSApp.windows.contains(where: { $0 !== panel && $0.isVisible && $0.canBecomeMain }) {
            NSApp.hide(nil)
        }
        updateButton()
    }

    private func resizePanel(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        panel.place(size: size)
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if cmd {
            switch chars {
            case ",": close(); openSettings(); return true
            case "q": NSApp.terminate(nil); return true
            case "w": close(); return true
            default: return false
            }
        }
        switch e.keyCode {
        case 53: close(); return true // esc
        case 36, 76: pad.toggleBelt(); return true // return, enter
        case 123, 125: pad.slower(); return true // ← ↓
        case 124, 126: pad.faster(); return true // → ↑
        default: break
        }
        switch chars {
        case " ", "s": pad.toggleBelt()
        case "+", "=": pad.faster()
        case "-", "_": pad.slower()
        case "m": pad.cycleMode()
        case "c": pad.toggleConnection()
        default: return false
        }
        return true
    }
}

/// A borderless, non-activating panel that hangs off the menu bar, with the
/// system's own popup material (Liquid Glass on macOS 26).
final class MenuBarPanel: NSPanel {
    var onResignKey: (() -> Void)?
    /// Top-left corner the panel hangs from, in screen coordinates.
    var anchor = NSPoint.zero
    var screenFrame = NSRect.zero

    private let cornerRadius: CGFloat

    init<Content: View>(content: Content) {
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []

        if #available(macOS 26.0, *) {
            cornerRadius = 22
        } else {
            cornerRadius = 12
        }

        super.init(contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = hosting
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            background = effect
        }
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    var contentSize: CGSize { contentView?.frame.size ?? .zero }

    /// Size the panel to its content, hanging from the anchor and kept on screen.
    func place(size: CGSize) {
        var x = anchor.x
        if screenFrame.width > 0 {
            x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)
        }
        let frame = NSRect(x: x.rounded(), y: (anchor.y - size.height).rounded(),
                           width: size.width, height: size.height)
        setFrame(frame, display: true, animate: false)
    }
}
