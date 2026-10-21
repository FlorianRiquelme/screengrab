import AppKit
import AVFoundation

/// Renders source-time selection and forwards editing intents to the recording owner.
@MainActor
final class RecordingTimeline: NSView {
    enum Edge { case start, end }

    enum Input {
        case begin(Edge)
        case adjust(Edge, CMTime)
        case end
        case cancel
        case scrub(CMTime)
        case step(Edge, Int)
        case togglePlayback
    }

    struct Presentation {
        let duration: CMTime
        let retained: CMTimeRange
        let playhead: CMTime
        let isPlaying: Bool
        let removesAudio: Bool
        let isEnabled: Bool

        init(duration: CMTime, retained: CMTimeRange, playhead: CMTime,
             isPlaying: Bool, removesAudio: Bool, isEnabled: Bool) {
            self.duration = duration
            self.retained = retained
            self.playhead = playhead
            self.isPlaying = isPlaying
            self.removesAudio = removesAudio
            self.isEnabled = isEnabled
        }
    }

    private enum Interaction {
        case idle
        case scrubbing
        case pointer(Edge, offset: CGFloat, lastX: CGFloat)
        case keyboard(Edge, keyCode: UInt16?)
    }

    var onInput: ((Input) -> Void)?

    private var presentation = Presentation(duration: .zero, retained: .zero, playhead: .zero,
                                            isPlaying: false, removesAudio: false, isEnabled: false)
    private var thumbnails: [NSImage] = []
    private var interaction: Interaction = .idle
    private let startHandle = Handle(edge: .start)
    private let endHandle = Handle(edge: .end)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { presentation.isEnabled }
    override var needsPanelToBecomeKey: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 92) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recording selection")
        for handle in [startHandle, endHandle] {
            handle.timeline = self
            addSubview(handle)
        }
        startHandle.nextKeyView = endHandle
    }

    func display(_ presentation: Presentation) {
        self.presentation = presentation
        if !presentation.isEnabled {
            interaction = .idle
            if let focused = window?.firstResponder as? NSView,
               focused === self || focused.isDescendant(of: self) {
                window?.makeFirstResponder(nil)
            }
        }
        for handle in [startHandle, endHandle] {
            let time = edgeTime(handle.edge)
            handle.setAccessibilityEnabled(presentation.isEnabled)
            handle.setAccessibilityMinValue(0)
            handle.setAccessibilityMaxValue(presentation.duration.seconds)
            handle.setAccessibilityValue(time.seconds)
            handle.setAccessibilityValueDescription(Self.timeString(time))
            handle.needsDisplay = true
        }
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func setThumbnails(_ images: [NSImage]) {
        thumbnails = images
        needsDisplay = true
    }

    private var strip: NSRect {
        NSRect(x: 26, y: 8, width: max(0, bounds.width - 52), height: 42)
    }

    override func layout() {
        super.layout()
        startHandle.frame = NSRect(x: x(for: presentation.retained.start) - 26, y: 4, width: 36, height: 50)
        endHandle.frame = NSRect(x: x(for: presentation.retained.end) - 10, y: 4, width: 36, height: 50)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let strip = strip
        let startX = x(for: presentation.retained.start)
        let endX = x(for: presentation.retained.end)
        let opacity: CGFloat = presentation.isEnabled ? 1 : 0.5

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: strip, xRadius: 5, yRadius: 5).addClip()
        NSColor.controlBackgroundColor.setFill()
        strip.fill()
        if !thumbnails.isEmpty {
            let width = strip.width / CGFloat(thumbnails.count)
            for (index, image) in thumbnails.enumerated() {
                let rect = NSRect(x: strip.minX + CGFloat(index) * width, y: strip.minY,
                                  width: width + 0.5, height: strip.height)
                let size = image.size
                guard size.width > 0, size.height > 0, rect.width > 0 else { continue }
                let scale = max(rect.width / size.width, rect.height / size.height)
                let sourceSize = NSSize(width: rect.width / scale, height: rect.height / scale)
                let source = NSRect(x: (size.width - sourceSize.width) / 2,
                                    y: (size.height - sourceSize.height) / 2,
                                    width: sourceSize.width, height: sourceSize.height)
                image.draw(in: rect, from: source, operation: .sourceOver, fraction: opacity,
                           respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            }
        }
        NSColor.black.withAlphaComponent(0.58).setFill()
        NSRect(x: strip.minX, y: strip.minY, width: startX - strip.minX, height: strip.height).fill()
        NSRect(x: endX, y: strip.minY, width: strip.maxX - endX, height: strip.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.controlAccentColor.withAlphaComponent(opacity).setStroke()
        let selection = NSBezierPath(roundedRect: NSRect(x: startX, y: strip.minY,
                                                       width: endX - startX, height: strip.height),
                                     xRadius: 3, yRadius: 3)
        selection.lineWidth = 2
        selection.stroke()
        drawPlayhead(at: x(for: presentation.playhead), opacity: opacity)

        let labelWidth = max(0, strip.width / 2 - 4)
        drawText("In " + Self.timeString(presentation.retained.start),
                 in: NSRect(x: strip.minX, y: 55, width: labelWidth, height: 15),
                 font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), alignment: .left)
        drawText("Out " + Self.timeString(presentation.retained.end),
                 in: NSRect(x: strip.maxX - labelWidth, y: 55, width: labelWidth, height: 15),
                 font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), alignment: .right)

        let font = NSFont.systemFont(ofSize: 11)
        let hint = presentation.isPlaying ? "Space to Pause" : "Space to Play"
        let hintWidth = ceil((hint as NSString).size(withAttributes: [.font: font]).width)
        drawText(hint, in: NSRect(x: 12, y: 75, width: hintWidth, height: 15), font: font, alignment: .left)
        let summary = Self.timeString(presentation.retained.duration) + " selected"
            + (presentation.removesAudio ? " · Audio removed" : "")
        drawText(summary, in: NSRect(x: hintWidth + 24, y: 75,
                                    width: max(0, bounds.width - hintWidth - 36), height: 15),
                 font: font, alignment: .right)
    }

    private func drawPlayhead(at x: CGFloat, opacity: CGFloat) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: strip.minY - 2))
        line.line(to: NSPoint(x: x, y: strip.maxY + 2))
        NSColor.black.withAlphaComponent(0.65 * opacity).setStroke()
        line.lineWidth = 3
        line.stroke()
        NSColor.white.withAlphaComponent(opacity).setStroke()
        line.lineWidth = 1
        line.stroke()
        let cap = NSBezierPath()
        cap.move(to: NSPoint(x: x - 4, y: strip.minY - 3))
        cap.line(to: NSPoint(x: x + 4, y: strip.minY - 3))
        cap.line(to: NSPoint(x: x, y: strip.minY + 2))
        cap.close()
        NSColor.white.withAlphaComponent(opacity).setFill()
        cap.fill()
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let color = presentation.isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color,
                                                         .paragraphStyle: paragraph])
    }

    private static func timeString(_ time: CMTime) -> String {
        let seconds = time.seconds
        guard seconds.isFinite else { return "--:--.---" }
        let milliseconds = Int64((seconds * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let wholeSeconds = milliseconds / 1_000 % 60
        let fraction = milliseconds % 1_000
        if hours > 0 {
            return String(format: "%lld:%02lld:%02lld.%03lld", hours, minutes, wholeSeconds, fraction)
        }
        return String(format: "%lld:%02lld.%03lld", milliseconds / 60_000, wholeSeconds, fraction)
    }

    private func edgeTime(_ edge: Edge) -> CMTime {
        switch edge {
        case .start: presentation.retained.start
        case .end: presentation.retained.end
        }
    }

    private func x(for time: CMTime) -> CGFloat {
        guard presentation.duration > .zero else { return strip.minX }
        return strip.minX + CGFloat(time.seconds / presentation.duration.seconds) * strip.width
    }

    private func time(at x: CGFloat) -> CMTime {
        guard strip.width > 0 else { return .zero }
        let fraction = min(1, max(0, (x - strip.minX) / strip.width))
        return CMTime(seconds: Double(fraction) * presentation.duration.seconds, preferredTimescale: 600_000)
    }

    private func send(_ input: Input) {
        guard presentation.isEnabled else { return }
        onInput?(input)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local) else { return nil }
        let hitsStart = startHandle.frame.contains(local)
        let hitsEnd = endHandle.frame.contains(local)
        if hitsStart && hitsEnd {
            let midpoint = (x(for: presentation.retained.start) + x(for: presentation.retained.end)) / 2
            return local.x <= midpoint ? startHandle : endHandle
        }
        if hitsStart { return startHandle }
        if hitsEnd { return endHandle }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { presentation.isEnabled }

    override func resetCursorRects() {
        guard presentation.isEnabled else { return }
        addCursorRect(strip, cursor: .pointingHand)
        for handle in [startHandle, endHandle] {
            addCursorRect(handle.frame.intersection(bounds), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard presentation.isEnabled else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard strip.insetBy(dx: 0, dy: -4).contains(point) else { return }
        finishInteraction()
        interaction = .scrubbing
        send(.scrub(time(at: point.x)))
    }

    override func mouseDragged(with event: NSEvent) { drag(with: event) }

    override func mouseUp(with event: NSEvent) {
        guard presentation.isEnabled else { return }
        drag(with: event)
        finishInteraction()
    }

    private func beginDrag(_ edge: Edge, with event: NSEvent) {
        guard presentation.isEnabled else { return }
        finishInteraction()
        let point = convert(event.locationInWindow, from: nil)
        interaction = .pointer(edge, offset: x(for: edgeTime(edge)) - point.x, lastX: point.x)
        send(.begin(edge))
    }

    private func drag(with event: NSEvent) {
        guard presentation.isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch interaction {
        case .pointer(let edge, let offset, let lastX):
            guard point.x != lastX else { return }
            interaction = .pointer(edge, offset: offset, lastX: point.x)
            send(.adjust(edge, time(at: point.x + offset)))
        case .scrubbing: send(.scrub(time(at: point.x)))
        case .idle, .keyboard: break
        }
    }

    private func finishInteraction(cancelled: Bool = false) {
        let previous = interaction
        interaction = .idle
        switch previous {
        case .pointer, .keyboard: send(cancelled ? .cancel : .end)
        case .idle, .scrubbing: break
        }
    }

    private func step(_ edge: Edge, by delta: Int, keyCode: UInt16?) {
        guard presentation.isEnabled else { return }
        if case .keyboard(let activeEdge, let activeKey) = interaction,
           activeEdge == edge, activeKey == keyCode {
            send(.step(edge, delta))
        } else {
            finishInteraction()
            interaction = .keyboard(edge, keyCode: keyCode)
            send(.begin(edge))
            send(.step(edge, delta))
        }
        if keyCode == nil { finishInteraction() }
    }

    private func handleKey(_ event: NSEvent, edge: Edge? = nil) -> Bool {
        guard presentation.isEnabled else { return true }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
            finishInteraction()
            if modifiers == .shift { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return true
        }
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 49 {
            finishInteraction()
            if !event.isARepeat { send(.togglePlayback) }
            return true
        }
        if event.keyCode == 53 {
            switch interaction {
            case .pointer, .keyboard:
                finishInteraction(cancelled: true)
                return true
            case .idle, .scrubbing: return false
            }
        }
        if let edge {
            switch event.keyCode {
            case 123, 125: step(edge, by: -1, keyCode: event.keyCode)
            case 124, 126: step(edge, by: 1, keyCode: event.keyCode)
            default: return false
            }
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    private func keyReleased(_ event: NSEvent) {
        if case .keyboard(_, let keyCode) = interaction, keyCode == event.keyCode {
            finishInteraction()
        }
    }

    private func handleResigned(_ edge: Edge) {
        if case .keyboard(let activeEdge, _) = interaction, activeEdge == edge {
            finishInteraction()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow == nil { finishInteraction(cancelled: true) }
        super.viewWillMove(toWindow: newWindow)
    }

    /// A real key-view and accessibility slider for one retained-range edge.
    @MainActor
    private final class Handle: NSView {
        let edge: Edge
        weak var timeline: RecordingTimeline?

        init(edge: Edge) {
            self.edge = edge
            super.init(frame: .zero)
            focusRingType = .exterior
            setAccessibilityElement(true)
            setAccessibilityRole(.slider)
            setAccessibilityOrientation(.horizontal)
            setAccessibilityLabel(edge == .start ? "Selection start" : "Selection end")
            setAccessibilityHelp("Use arrow keys to move one frame. Space plays or pauses the selection.")
            setAccessibilityEnabled(false)
        }

        required init?(coder: NSCoder) { return nil }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { timeline?.presentation.isEnabled == true }
        override var needsPanelToBecomeKey: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override var focusRingMaskBounds: NSRect { grip.insetBy(dx: -3, dy: -3) }

        private var grip: NSRect {
            NSRect(x: (edge == .start ? 26 : 10) - 5, y: 4, width: 10, height: 42)
        }

        override func draw(_ dirtyRect: NSRect) {
            let opacity: CGFloat = timeline?.presentation.isEnabled == true ? 1 : 0.5
            NSColor.controlAccentColor.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3).fill()
            NSColor.selectedControlTextColor.withAlphaComponent(opacity).setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: grip.midX, y: grip.midY - 6))
            line.line(to: NSPoint(x: grip.midX, y: grip.midY + 6))
            line.lineWidth = 1.5
            line.stroke()
        }

        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 5, yRadius: 5).fill()
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            needsDisplay = true
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { timeline?.handleResigned(edge) }
            needsDisplay = true
            return accepted
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstResponder }

        override func mouseDown(with event: NSEvent) {
            guard acceptsFirstResponder else { return }
            window?.makeFirstResponder(self)
            timeline?.beginDrag(edge, with: event)
        }

        override func mouseDragged(with event: NSEvent) { timeline?.drag(with: event) }
        override func mouseUp(with event: NSEvent) { timeline?.mouseUp(with: event) }

        override func keyDown(with event: NSEvent) {
            if timeline?.handleKey(event, edge: edge) != true { super.keyDown(with: event) }
        }

        override func keyUp(with event: NSEvent) { timeline?.keyReleased(event) }

        override func accessibilityPerformIncrement() -> Bool {
            guard acceptsFirstResponder else { return false }
            timeline?.step(edge, by: 1, keyCode: nil)
            return true
        }

        override func accessibilityPerformDecrement() -> Bool {
            guard acceptsFirstResponder else { return false }
            timeline?.step(edge, by: -1, keyCode: nil)
            return true
        }
    }
}
