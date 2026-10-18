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
/// While tips show, → and ← step through them and Esc skips all, before the surface sees those keys.
@MainActor
enum Tips {
    private static let skipKey = "tipsSkipped"
    private static var surface: TipSurface?
    private static var queue: [Tip] = []
    private static var index = 0
    private static var keyMonitor: Any?
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 124: next()
            case 123: back()
            case 53: skipAll()
            default: return event
            }
            return nil
        }
        step()
    }

    /// For a surface closing: drops its tips so no popover outlives it.
    static func dismiss(in window: NSWindow) {
        if isShowing, queue[index].anchor.window === window || queue[index].anchor.window == nil { finish() }
    }

    static func resetAll() {
        let d = UserDefaults.standard
        d.removeObject(forKey: skipKey)
        for s in TipSurface.allCases { d.removeObject(forKey: seenKey(s)) }
    }

    fileprivate static func next() {
        index += 1
        if index < queue.count { step() } else { finish() }
    }

    fileprivate static func back() {
        guard index > 0 else { return }
        index -= 1
        step()
    }

    fileprivate static func skipAll() {
        UserDefaults.standard.set(true, forKey: skipKey)
        close()
    }

    /// Marks the surface seen and closes its tips.
    private static func finish() {
        if let surface { UserDefaults.standard.set(true, forKey: seenKey(surface)) }
        close()
    }

    private static func step() {
        let tip = queue[index]
        guard let window = tip.anchor.window, window.isVisible else { return finish() }
        controller.load(tip, counter: queue.count > 1 ? "\(index + 1) of \(queue.count)" : "", isFirst: index == 0, isLast: index == queue.count - 1)
        popover.contentSize = controller.view.fittingSize
        let edge: NSRectEdge = switch (tip.edge, tip.anchor.isFlipped) {
        case (.maxY, true): .minY
        case (.minY, true): .maxY
        default: tip.edge
        }
        popover.show(relativeTo: tip.anchor.bounds, of: tip.anchor, preferredEdge: edge)
        if window.canBecomeKey {
            // Clicking a tip button makes the popover key; hand keys back so the surface's shortcuts keep working.
            window.makeKey()
        } else {
            // The menu bar icon's window never takes keys, so the arrow keys need the app active and the tip key.
            NSApp.activate()
            controller.view.window?.makeKey()
        }
    }

    private static func close() {
        surface = nil
        queue = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        popover.close()
    }
}

private final class TipController: NSViewController {
    private let text = NSTextField(wrappingLabelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let backButton = NSButton(title: "", target: nil, action: nil)
    private let nextButton = NSButton(title: "", target: nil, action: nil)
    private let skipButton = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?
    private lazy var textWidth = text.widthAnchor.constraint(equalToConstant: 260)
    private let row = NSStackView()

    override func loadView() {
        text.font = .systemFont(ofSize: 13)
        counter.font = .systemFont(ofSize: 11)
        counter.textColor = .secondaryLabelColor
        for (b, sel) in [(skipButton, #selector(skipPressed)), (actionButton, #selector(actionPressed)),
                         (backButton, #selector(backPressed)), (nextButton, #selector(nextPressed))] {
            b.target = self
            b.action = sel
            b.controlSize = .small
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        skipButton.attributedTitle = Self.title("Skip All", shortcut: "esc")
        backButton.attributedTitle = Self.title("Back", shortcut: "←")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.setViews([counter, spacer, skipButton, actionButton, backButton, nextButton], in: .leading)
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

    /// The same title-then-key look as the preview's buttons.
    private static func title(_ title: String, shortcut: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        text.append(NSAttributedString(string: "  \(shortcut)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    func load(_ tip: Tip, counter: String, isFirst: Bool, isLast: Bool) {
        _ = view
        text.stringValue = tip.text
        self.counter.stringValue = counter
        backButton.isHidden = isFirst
        nextButton.attributedTitle = Self.title(isLast ? "Done" : "Next", shortcut: "→")
        action = tip.action?.run
        actionButton.title = tip.action?.title ?? ""
        actionButton.isHidden = tip.action == nil
        // Wraps at 260pt unless the buttons need more room.
        textWidth.constant = 260
        textWidth.constant = max(260, row.fittingSize.width)
        text.preferredMaxLayoutWidth = textWidth.constant
    }

    @objc private func nextPressed() { Tips.next() }
    @objc private func backPressed() { Tips.back() }
    @objc private func skipPressed() { Tips.skipAll() }
    @objc private func actionPressed() { action?() }
}
