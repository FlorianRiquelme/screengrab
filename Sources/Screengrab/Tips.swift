import AppKit

enum TipSurface: String, CaseIterable {
    case setup, screenshotPreview, scrollCapture, recordingBar, recordingPreview
}

/// One explanation, pointing at the control it explains.
struct Tip {
    let anchor: NSView
    let text: String
    /// In screen terms: `.maxY` is above the anchor, whether or not its view is flipped.
    var edge: NSRectEdge = .maxY
    var action: (title: String, run: () -> Void)?
}

/// Shows each surface's tips once, one popover at a time, until the user has seen them or skipped them all.
@MainActor
enum Tips {
    private static let skipKey = "tipsSkipped"
    private static var surface: TipSurface?
    private static var queue: [Tip] = []
    private static var index = 0
    private static let controller = TipController()
    private static let popover: NSPopover = {
        let p = NSPopover()
        // Application-defined: clicks on the surface go through and leave the tip open.
        p.behavior = .applicationDefined
        p.contentViewController = controller
        return p
    }()

    private static func seenKey(_ surface: TipSurface) -> String { "tipsSeen.\(surface.rawValue)" }

    static var isShowing: Bool { surface != nil }

    static func show(_ surface: TipSurface, _ tips: [Tip]) {
        let d = UserDefaults.standard
        guard !isShowing, !tips.isEmpty, !d.bool(forKey: skipKey), !d.bool(forKey: seenKey(surface)) else { return }
        self.surface = surface
        queue = tips
        index = 0
        step()
    }

    /// Closes the tips and marks their surface seen. Returns whether any were showing, so Esc can stop there.
    @discardableResult
    static func dismissIfShowing() -> Bool {
        guard let surface else { return false }
        UserDefaults.standard.set(true, forKey: seenKey(surface))
        close()
        return true
    }

    /// For a surface closing: drops its tips so no popover outlives it.
    static func dismiss(in window: NSWindow) {
        if isShowing, queue[index].anchor.window === window || queue[index].anchor.window == nil { dismissIfShowing() }
    }

    static func resetAll() {
        let d = UserDefaults.standard
        d.removeObject(forKey: skipKey)
        for s in TipSurface.allCases { d.removeObject(forKey: seenKey(s)) }
    }

    fileprivate static func next() {
        index += 1
        if index < queue.count { step() } else { dismissIfShowing() }
    }

    fileprivate static func skipAll() {
        UserDefaults.standard.set(true, forKey: skipKey)
        close()
    }

    private static func step() {
        let tip = queue[index]
        guard let window = tip.anchor.window, window.isVisible else { dismissIfShowing(); return }
        controller.load(tip, counter: queue.count > 1 ? "\(index + 1) of \(queue.count)" : "", isLast: index == queue.count - 1)
        popover.contentSize = controller.view.fittingSize
        let edge: NSRectEdge = switch (tip.edge, tip.anchor.isFlipped) {
        case (.maxY, true): .minY
        case (.minY, true): .maxY
        default: tip.edge
        }
        popover.show(relativeTo: tip.anchor.bounds, of: tip.anchor, preferredEdge: edge)
        // Clicking Next makes the popover key; hand keys back so the surface's shortcuts keep working.
        if window.canBecomeKey { window.makeKey() }
    }

    private static func close() {
        surface = nil
        queue = []
        popover.close()
    }
}

private final class TipController: NSViewController {
    private let text = NSTextField(wrappingLabelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private var action: (() -> Void)?
    private lazy var textWidth = text.widthAnchor.constraint(equalToConstant: 260)
    private let row = NSStackView()

    override func loadView() {
        text.font = .systemFont(ofSize: 13)
        counter.font = .systemFont(ofSize: 11)
        counter.textColor = .secondaryLabelColor
        let skip = NSButton(title: "Skip All", target: self, action: #selector(skipPressed))
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        nextButton.target = self
        nextButton.action = #selector(nextPressed)
        nextButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.setViews([counter, spacer, skip, actionButton, nextButton], in: .leading)
        for b in [skip, actionButton, nextButton] {
            b.controlSize = .small
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let stack = NSStackView(views: [text, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            row.widthAnchor.constraint(equalTo: text.widthAnchor),
            textWidth,
        ])
        view = container
    }

    func load(_ tip: Tip, counter: String, isLast: Bool) {
        _ = view
        text.stringValue = tip.text
        self.counter.stringValue = counter
        nextButton.title = isLast ? "Done" : "Next"
        action = tip.action?.run
        actionButton.title = tip.action?.title ?? ""
        actionButton.isHidden = tip.action == nil
        // Wraps at 260pt unless the buttons need more room.
        textWidth.constant = 260
        textWidth.constant = max(260, row.fittingSize.width)
        text.preferredMaxLayoutWidth = textWidth.constant
    }

    override func cancelOperation(_ sender: Any?) { Tips.dismissIfShowing() }

    @objc private func nextPressed() { Tips.next() }
    @objc private func skipPressed() { Tips.skipAll() }
    @objc private func actionPressed() { action?() }
}
