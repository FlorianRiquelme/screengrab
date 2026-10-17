import AppKit

/// Click-through overlay over the recorded display that animates a ring at every mouse-down.
@MainActor
final class ClickRipples {
    private static let radius: CGFloat = 34
    private static let duration: CFTimeInterval = 0.45

    private let panel = NSPanel.overlay(frame: .zero, level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
    private var monitors: [Any] = []

    init() {
        panel.ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
    }

    func start(on screen: NSScreen) {
        stop()
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.ripple(at: NSEvent.mouseLocation) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.ripple(at: NSEvent.mouseLocation) }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
        panel.contentView?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    private func ripple(at screenPoint: NSPoint) {
        guard let layer = panel.contentView?.layer, panel.frame.contains(screenPoint) else { return }
        let center = CGPoint(x: screenPoint.x - panel.frame.minX, y: screenPoint.y - panel.frame.minY)
        let ring = CALayer()
        ring.bounds = CGRect(x: 0, y: 0, width: Self.radius * 2, height: Self.radius * 2)
        ring.position = center
        let yellow = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.1, alpha: 1)
        ring.addSublayer(circle(width: 0, stroke: nil, fill: yellow.withAlphaComponent(0.3)))
        ring.addSublayer(circle(width: 8, stroke: NSColor.black.withAlphaComponent(0.5), fill: nil))
        ring.addSublayer(circle(width: 4, stroke: yellow, fill: nil))
        layer.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 1.0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.45, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Self.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    private func circle(width: CGFloat, stroke: NSColor?, fill: NSColor?) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.frame = CGRect(x: 0, y: 0, width: Self.radius * 2, height: Self.radius * 2)
        shape.path = CGPath(ellipseIn: shape.bounds.insetBy(dx: 5, dy: 5), transform: nil)
        shape.fillColor = fill?.cgColor
        shape.strokeColor = stroke?.cgColor
        shape.lineWidth = width
        return shape
    }
}
