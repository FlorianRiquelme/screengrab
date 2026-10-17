import AppKit

/// Click-through dashed frame drawn just outside the selected area.
@MainActor
final class AreaOutline {
    private static let gap: CGFloat = 3
    private let panel = NSPanel.overlay(frame: .zero, level: .floating)

    var windowNumber: Int { panel.windowNumber }
    var isVisible: Bool { panel.isVisible }

    init() {
        panel.ignoresMouseEvents = true
        panel.contentView = DashedBorderView()
    }

    func show(around rect: NSRect) {
        panel.setFrame(rect.insetBy(dx: -Self.gap, dy: -Self.gap), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class DashedBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.black.withAlphaComponent(0.6).setStroke()
        path.stroke()
        path.setLineDash([8, 6], count: 2, phase: 0)
        NSColor.white.setStroke()
        path.stroke()
    }
}
