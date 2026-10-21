import AppKit

/// What a selection offers: the screens it covers, whether Space switches to picking a window,
/// and the hint shown while picking an area.
struct SelectionMode {
    var screens: [NSScreen]
    var allowsWindows: Bool
    var areaHint: String

    static func recordingArea(on screen: NSScreen) -> SelectionMode {
        SelectionMode(screens: [screen], allowsWindows: false, areaHint: "Drag to select the recording area, hold Space while dragging to move it. Esc cancels.")
    }

    static var screenshot: SelectionMode {
        SelectionMode(screens: NSScreen.screens, allowsWindows: true, areaHint: "Drag to capture an area, hold Space while dragging to move it. Space: window. Esc cancels.")
    }

    static var scrollingCapture: SelectionMode {
        SelectionMode(screens: NSScreen.screens, allowsWindows: false, areaHint: "Drag over the content you'll scroll, hold Space while dragging to move it. Esc cancels.")
    }
}

/// Covers each screen of the mode with a panel. A drag on any of them picks an area of that display; in window
/// mode a click picks the highlighted window. Completes once, with nil when cancelled with Esc.
@MainActor
final class CaptureSelector {
    private static let windowHint = "Click a window to capture it. Space: area. Esc cancels."

    private enum Picking {
        case area
        case window([CapturableWindow], hovered: CapturableWindow?)
    }

    private let mode: SelectionMode
    private var panels: [SelectorPanel] = []
    private var picking = Picking.area
    private var completion: ((CaptureTarget?) -> Void)?

    static func begin(_ mode: SelectionMode, completion: @escaping (CaptureTarget?) -> Void) -> CaptureSelector {
        let selector = CaptureSelector(mode: mode, completion: completion)
        let mouseDisplay = screenUnderMouse().displayID
        let key = selector.panels.first { $0.targetScreen.displayID == mouseDisplay } ?? selector.panels[0]
        selector.panels.forEach { $0.orderFrontRegardless() }
        key.makeKeyAndOrderFront(nil)
        return selector
    }

    private init(mode: SelectionMode, completion: @escaping (CaptureTarget?) -> Void) {
        self.mode = mode
        self.completion = completion
        panels = mode.screens.map { screen in
            let panel = SelectorPanel(screen: screen, hint: mode.areaHint)
            panel.onKey = { [weak self] event in self?.handle(event) ?? false }
            panel.view.onArea = { [weak self, unowned panel] rect in
                let screen = panel.targetScreen
                self?.finish(.area(displayID: screen.displayID, rect: screen.displayRect(fromCocoa: rect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY))))
            }
            panel.view.onClick = { [weak self] in
                guard let self, case .window(_, let hovered?) = picking else { return }
                finish(.window(hovered.id))
            }
            panel.view.onMouseMoved = { [weak self] in self?.updateHover() }
            return panel
        }
    }

    /// Removes the panels without completing.
    func dismiss() {
        completion = nil
        panels.forEach { $0.orderOut(nil) }
    }

    private func finish(_ target: CaptureTarget?) {
        guard let completion else { return }
        dismiss()
        completion(target)
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch (event.keyCode, event.type) {
        case (53, .keyDown):
            finish(nil)
        case (49, .keyDown) where dragging != nil:
            if !event.isARepeat { dragging?.setMoving(true) }
        case (49, .keyUp):
            panels.forEach { $0.view.setMoving(false) }
        case (49, .keyDown) where mode.allowsWindows:
            if !event.isARepeat { toggleWindowMode() }
        default:
            return false
        }
        return true
    }

    private var dragging: SelectionView? { panels.first { $0.view.isDragging }?.view }

    private func toggleWindowMode() {
        if case .area = picking {
            picking = .window(CapturableWindow.onScreen(), hovered: nil)
            updateHover()
        } else {
            picking = .area
        }
        render()
    }

    private func updateHover() {
        guard case .window(let windows, let hovered) = picking else { return }
        let point = NSEvent.mouseLocation.flippedGlobal(primaryHeight: primaryHeight)
        let under = windows.first { $0.frame.contains(point) }
        guard under != hovered else { return }
        picking = .window(windows, hovered: under)
        render()
    }

    private func render() {
        for panel in panels {
            switch picking {
            case .area:
                panel.view.show(.area, hint: mode.areaHint)
            case .window(_, let hovered):
                let highlight = hovered.map {
                    $0.frame.flippedGlobal(primaryHeight: primaryHeight).offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
                }
                panel.view.show(.window(highlight: highlight), hint: Self.windowHint)
            }
        }
    }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

private final class SelectorPanel: NSPanel {
    let targetScreen: NSScreen
    let view: SelectionView
    var onKey: ((NSEvent) -> Bool)?

    init(screen: NSScreen, hint: String) {
        targetScreen = screen
        view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), hint: hint)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Window mode leaves the panel transparent, and transparent pixels would otherwise pass clicks through.
        ignoresMouseEvents = false
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if onKey?(event) != true { super.keyUp(with: event) }
    }
}

/// Shifts a selection's two corners by `delta`, stopped at the edges of `bounds` so its size holds.
func movedSelection(anchor: CGPoint, current: CGPoint, by delta: CGPoint, within bounds: CGRect) -> (anchor: CGPoint, current: CGPoint) {
    let minX = min(anchor.x, current.x), maxX = max(anchor.x, current.x)
    let minY = min(anchor.y, current.y), maxY = max(anchor.y, current.y)
    let dx = min(max(delta.x, bounds.minX - minX), bounds.maxX - maxX)
    let dy = min(max(delta.y, bounds.minY - minY), bounds.maxY - maxY)
    return (CGPoint(x: anchor.x + dx, y: anchor.y + dy), CGPoint(x: current.x + dx, y: current.y + dy))
}

private final class SelectionView: NSView {
    enum State {
        case area
        case window(highlight: NSRect?)
    }

    var onArea: ((NSRect) -> Void)?
    var onClick: (() -> Void)?
    var onMouseMoved: (() -> Void)?
    private var state = State.area
    private var anchor: NSPoint?
    private var current: NSPoint?
    private var isMoving = false
    private var grip: NSPoint?
    private let hint = NSGlassEffectView()
    private let label = NSTextField(labelWithString: "")

    init(frame: NSRect, hint text: String) {
        super.init(frame: frame)
        label.stringValue = text
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        hint.contentView = content
        hint.appearance = NSAppearance(named: .darkAqua)
        hint.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(hint)
        layoutHint()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: State, hint text: String) {
        self.state = state
        anchor = nil
        current = nil
        isMoving = false
        grip = nil
        hint.isHidden = false
        if label.stringValue != text {
            label.stringValue = text
            layoutHint()
        }
        needsDisplay = true
    }

    var isDragging: Bool { anchor != nil }

    func setMoving(_ moving: Bool) {
        guard moving != isMoving else { return }
        if moving {
            guard let a = anchor, let c = current else { return }
            isMoving = true
            grip = c
            anchor = clamped(a)
            current = clamped(c)
            NSCursor.closedHand.set()
        } else {
            isMoving = false
            grip = nil
            NSCursor.crosshair.set()
        }
    }

    private func clamped(_ p: NSPoint) -> NSPoint {
        NSPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private func layoutHint() {
        let size = hint.fittingSize
        hint.cornerRadius = size.height / 2
        hint.frame = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                            width: size.width, height: size.height)
    }

    private var selection: NSRect? {
        guard let anchor, let current else { return nil }
        return NSRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                      width: abs(current.x - anchor.x), height: abs(current.y - anchor.y)).intersection(bounds)
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        onMouseMoved?()
    }

    override func mouseDown(with event: NSEvent) {
        guard case .area = state else { return }
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        hint.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        if isMoving, let grip, let current {
            let moved = movedSelection(anchor: anchor, current: current, by: CGPoint(x: point.x - grip.x, y: point.y - grip.y), within: bounds)
            self.anchor = moved.anchor
            self.current = moved.current
            self.grip = point
        } else {
            current = point
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .window = state {
            onClick?()
            return
        }
        if !isMoving { current = convert(event.locationInWindow, from: nil) }
        let rect = selection
        anchor = nil
        current = nil
        isMoving = false
        grip = nil
        hint.isHidden = false
        needsDisplay = true
        if let rect, rect.width >= 8, rect.height >= 8 { onArea?(rect.integral) }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch state {
        case .area:
            drawArea()
        case .window(let highlight?):
            NSColor.systemBlue.withAlphaComponent(0.25).setFill()
            highlight.fill()
            NSColor.systemBlue.setStroke()
            let outline = NSBezierPath(rect: highlight.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
        case .window(nil):
            break
        }
    }

    private func drawArea() {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let selection else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
        let size = "\(Int(selection.width)) × \(Int(selection.height))"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let text = NSAttributedString(string: size, attributes: attrs)
        var origin = NSPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + 16 > bounds.maxY { origin.y = selection.minY - 20 }
        let box = NSRect(origin: origin, size: NSSize(width: text.size().width + 10, height: 18))
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2))
    }
}
