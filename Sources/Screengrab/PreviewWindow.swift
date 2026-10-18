import AppKit
import AVKit
import UniformTypeIdentifiers

enum PreviewContent {
    case screenshot(URL, ownsFile: Bool)
    case recording(URL, interruption: String?)

    var url: URL {
        switch self {
        case .screenshot(let url, _), .recording(let url, _): url
        }
    }

    var ownsFile: Bool {
        if case .screenshot(_, let owns) = self { owns } else { false }
    }

    @MainActor
    var actions: [PreviewAction] {
        switch self {
        case .screenshot:
            [
                PreviewAction(title: "Copy Path", symbol: "link", key: "c", shortcut: "⌘C", optionTitle: "Copy Path 2x") { $0.copyScreenshotPath(oneX: !$1) },
                PreviewAction(title: "Copy Image", symbol: "doc.on.doc", key: "c", modifiers: [.command, .shift], shortcut: "⇧⌘C", optionTitle: "Copy Image 1x") { $0.copyScreenshot(oneX: $1) },
                PreviewAction(title: "Copy Text", symbol: "text.viewfinder", key: "t", shortcut: "⌘T") { w, _ in w.copyScreenshotText() },
                PreviewAction(title: "Save", symbol: "square.and.arrow.down", key: "s", shortcut: "⌘S") { w, _ in w.saveScreenshot() },
            ]
        case .recording:
            [
                PreviewAction(title: "Copy", symbol: "doc.on.doc", key: "c", shortcut: "⌘C") { w, _ in w.copyRecording() },
                PreviewAction(title: "Show in Finder", symbol: "folder", key: "r", shortcut: "⌘R") { w, _ in w.revealRecording() },
                PreviewAction(title: "Delete", symbol: "trash", key: "\u{7F}", shortcut: "⌘⌫") { w, _ in w.trashRecording() },
            ]
        }
    }
}

struct PreviewAction {
    let title: String
    let symbol: String
    let key: String
    var modifiers: NSEvent.ModifierFlags = .command
    let shortcut: String
    /// Shown instead of `title` while Option is held; the handler then gets `option` true.
    var optionTitle: String?
    let handler: @MainActor (PreviewWindow, _ option: Bool) -> Void

    func label(option: Bool) -> (title: String, shortcut: String) {
        option && optionTitle != nil ? (optionTitle!, "⌥" + shortcut) : (title, shortcut)
    }
}

@MainActor
final class PreviewWindow: NSPanel, NSWindowDelegate {
    private static var open: [PreviewWindow] = []
    static var isShowing: Bool { !open.isEmpty }
    private static let padding: CGFloat = 12
    private static let imageRadius: CGFloat = 16
    private static let buttonWidth: CGFloat = 96
    private static let buttonSpacing: CGFloat = 12
    private static let fallbackVideoSize = CGSize(width: 640, height: 360)
    /// A tall image fitted whole would be a sliver; below this width it keeps this width and scrolls instead.
    private static let minImageWidth: CGFloat = 360

    private let content: PreviewContent
    private let actions: [PreviewAction]
    private let image: NSImage?
    private let base: CGImage?
    private var markupView: MarkupView?
    private var markup = Markup() { didSet { markupView?.annotations = markup.annotations } }
    private var tool = MarkupTool.drag { didSet { markupView?.tool = tool; toolPicker?.selectedSegment = MarkupTool.allCases.firstIndex(of: tool)! } }
    private var toolPicker: NSSegmentedControl?
    private var media: NSView?
    private var rendered: (annotations: [Annotation], url: URL)?
    private var player: AVPlayer?
    private var isDismissing = false
    private var buttons: [NSButton] = []
    private var notice: (index: Int, text: String)?
    private let sourceScale: CGFloat

    static func show(_ content: PreviewContent) async {
        var image: NSImage?
        var base: CGImage?
        let pixelSize: CGSize
        switch content {
        case .screenshot(let url, let ownsFile):
            guard let loaded = NSImage(contentsOf: url),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                if ownsFile { try? FileManager.default.removeItem(at: url) }
                return
            }
            let rep = loaded.representations.first
            pixelSize = CGSize(width: rep?.pixelsWide ?? Int(loaded.size.width), height: rep?.pixelsHigh ?? Int(loaded.size.height))
            image = loaded
            base = cgImage
        case .recording(let url, _):
            let asset = AVURLAsset(url: url)
            let track = try? await asset.loadTracks(withMediaType: .video).first
            pixelSize = if let track, let size = try? await track.load(.naturalSize) { size } else { fallbackVideoSize }
        }
        let w = PreviewWindow(content: content, image: image, base: base, pixelSize: pixelSize)
        open.append(w)
        w.present(cascadeIndex: open.count - 1)
    }

    private init(content: PreviewContent, image: NSImage?, base: CGImage?, pixelSize: CGSize) {
        self.content = content
        self.actions = content.actions
        self.image = image
        self.base = base

        let screen = screenUnderMouse()
        let scale = screen.backingScaleFactor
        // The file's DPI, not the preview's screen, says how it was captured; 72 DPI files count as 1x.
        sourceScale = image.flatMap { img in img.representations.first.map { CGFloat($0.pixelsWide) / img.size.width } } ?? 1
        let natural = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        let vis = screen.visibleFrame
        let fit = min(1, 0.7 * vis.width / natural.width, 0.7 * vis.height / natural.height)
        let scrollFit = min(1, Self.minImageWidth / natural.width)
        let scrolls = image != nil && fit < scrollFit
        let shown = scrolls ? scrollFit : fit
        let imageSize = CGSize(width: (natural.width * shown).rounded(), height: (natural.height * shown).rounded())
        let size = scrolls ? CGSize(width: imageSize.width, height: (0.7 * vis.height).rounded()) : imageSize

        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Titled rather than borderless: a sheet on a borderless window dims a square-cornered rect.
        title = image == nil ? "Recording" : "Screenshot"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        isOpaque = false
        backgroundColor = .clear
        // A titled window's shadow comes with a dark outline that reads as a frame around the glass.
        hasShadow = false
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        delegate = self

        let media: NSView
        switch content {
        case .screenshot:
            let imageView = MarkupView(base: base!, scale: sourceScale)
            imageView.onAdd = { [unowned self] in markup.add($0) }
            imageView.fileURL = { [unowned self] in try? exportURL() }
            markupView = imageView
            if scrolls {
                imageView.frame = NSRect(origin: .zero, size: imageSize)
                let scrollView = NSScrollView()
                scrollView.documentView = imageView
                scrollView.hasVerticalScroller = true
                scrollView.scrollerStyle = .overlay
                scrollView.drawsBackground = false
                media = scrollView
            } else {
                media = imageView
            }
        case .recording(let url, _):
            let playerView = AVPlayerView()
            let player = AVPlayer(url: url)
            playerView.player = player
            playerView.controlsStyle = .inline
            self.player = player
            media = playerView
        }
        media.wantsLayer = true
        media.layer?.cornerRadius = min(Self.imageRadius, min(size.width, size.height) / 4)
        media.layer?.cornerCurve = .continuous
        media.layer?.masksToBounds = true
        media.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        media.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        self.media = media

        buttons = actions.indices.map { button(for: $0) }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.spacing = Self.buttonSpacing

        let p = Self.padding
        var views = [media]
        if case .recording(_, let interruption?) = content {
            let label = NSTextField(labelWithString: "Recording stopped early: \(interruption)")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(lessThanOrEqualTo: media.widthAnchor).isActive = true
            views.append(label)
        }
        if markupView != nil {
            let picker = NSSegmentedControl(labels: MarkupTool.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(toolPicked(_:)))
            for (i, t) in MarkupTool.allCases.enumerated() {
                picker.setImage(NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil), forSegment: i)
                picker.setLabel("\(t.title)  \(t.key.uppercased())", forSegment: i)
                picker.setToolTip(t == .drag ? "Drag the image to Finder or another app (D)" : "\(t.title) (\(t.key.uppercased())). Drag on the image; ⌘Z undoes, Esc goes back to Drag.", forSegment: i)
            }
            picker.selectedSegment = 0
            picker.controlSize = .large
            toolPicker = picker
            views.append(picker)
        }
        views.append(buttonRow)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = p
        stack.translatesAutoresizingMaskIntoConstraints = false
        let rowWidth = buttonRow.fittingSize.width
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: max(320 - 2 * p, rowWidth)).isActive = true

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -p),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -p - 2),
        ])
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.imageRadius + p
        glass.contentView = container
        contentView = glass
        setContentSize(glass.fittingSize)
    }

    @objc private func toolPicked(_ sender: NSSegmentedControl) { tool = MarkupTool.allCases[sender.selectedSegment] }

    private func button(for index: Int) -> NSButton {
        let action = actions[index]
        let b = NSButton(title: action.title, image: NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)!, target: self, action: #selector(buttonPressed(_:)))
        b.tag = index
        b.bezelStyle = .glass
        b.controlSize = .extraLarge
        b.imagePosition = .imageLeading
        // Fixed to the wider of the two labels so toggling Option never resizes the row.
        let width = [false, true].map { b.attributedTitle = attributedTitle(for: action, option: $0); return b.fittingSize.width }.max()!
        b.widthAnchor.constraint(equalToConstant: max(Self.buttonWidth, width.rounded(.up))).isActive = true
        b.attributedTitle = attributedTitle(for: action, option: false)
        return b
    }

    private func attributedTitle(for action: PreviewAction, option: Bool, notice: String? = nil) -> NSAttributedString {
        let label = action.label(option: option)
        let text = NSMutableAttributedString(string: notice ?? label.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        if notice == nil {
            text.append(NSAttributedString(string: "  \(label.shortcut)", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }

    private var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

    private func refreshButtons() {
        for (i, b) in buttons.enumerated() {
            b.attributedTitle = attributedTitle(for: actions[i], option: optionHeld, notice: notice?.index == i ? notice?.text : nil)
        }
    }

    private func flash(_ text: String, on index: Int) {
        notice = (index, text)
        refreshButtons()
        NSSound.beep()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.notice = nil
            self?.refreshButtons()
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) { perform(actions[sender.tag], option: optionHeld) }

    private func perform(_ action: PreviewAction, option: Bool) {
        guard !isDismissing else { return }
        action.handler(self, option)
    }

    override func flagsChanged(with event: NSEvent) {
        refreshButtons()
        super.flagsChanged(with: event)
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshButtons() }

    private func present(cascadeIndex: Int) {
        let vis = screenUnderMouse().visibleFrame
        let step = CGFloat(cascadeIndex % 8) * 28
        let f = frame
        setFrameOrigin(NSPoint(x: (vis.midX - f.width / 2 + step).rounded(), y: (vis.midY - f.height / 2 - step).rounded()))
        alphaValue = 0
        // Activation requests from a background app can be refused; a non-activating panel still takes key focus.
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
        showTips()
    }

    private func showTips() {
        let button = { (title: String) in self.buttons[self.actions.firstIndex { $0.title == title }!] }
        switch content {
        case .screenshot:
            guard let toolPicker, let media else { return }
            let tool = MarkupTool.allCases.map { $0.key.uppercased() }.joined(separator: ", ")
            Tips.show(.screenshotPreview, [
                Tip(anchor: toolPicker, text: "Drag the image into any app. Arrow, Box and Blur mark it up; press \(tool)."),
                Tip(anchor: button("Copy Path"), text: "Saves a copy and copies its path, ready to paste to an agent. Copies are \(CacheRetention.current.phrase); change that in the menu bar.", edge: .minY),
                Tip(anchor: button("Copy Image"), text: "Copies the image itself, for chats and docs.", edge: .minY),
                Tip(anchor: button("Copy Text"), text: "Copies any text in the screenshot.", edge: .minY),
                Tip(anchor: button("Save"), text: "Saves a file you keep. It opens in \(SaveFolder.name); change that in the menu bar.", edge: .minY),
                Tip(anchor: media, text: "Esc throws the screenshot away. Nothing is kept unless you copy its path or save it."),
            ])
        case .recording:
            Tips.show(.recordingPreview, [
                Tip(anchor: button("Copy"), text: "Puts the video file on the clipboard, ready to paste into a chat or email.", edge: .minY),
                Tip(anchor: button("Show in Finder"), text: "Recordings are kept in ~/Movies/Screengrab.", edge: .minY),
                Tip(anchor: button("Delete"), text: "Moves it to the Trash.", edge: .minY),
            ])
        }
    }

    fileprivate func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        Tips.dismiss(in: self)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let option = flags.contains(.option)
        flags.remove(.option)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        if key == "w" && flags == .command {
            dismiss()
        } else if key == "z" && markupView != nil && (flags == .command || flags == [.command, .shift]) {
            if flags == .command { markup.undo() } else { markup.redo() }
        } else if let action = actions.first(where: { $0.key == key && $0.modifiers == flags }) {
            perform(action, option: option)
        } else {
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modified = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.keyCode == 53 {
            cancelOperation(nil)
        } else if markupView != nil, !modified, let picked = MarkupTool.allCases.first(where: { $0.key == event.charactersIgnoringModifiers?.lowercased() }) {
            tool = picked
        } else {
            super.keyDown(with: event)
        }
    }

    /// Esc first steps back from a drawing tool to Drag, so only a second Esc discards.
    override func cancelOperation(_ sender: Any?) {
        if markupView != nil && tool != .drag { tool = .drag } else { dismiss() }
    }

    func windowWillClose(_ notification: Notification) {
        Tips.dismiss(in: self)
        Self.open.removeAll { $0 === self }
        player?.pause()
        player = nil
        if content.ownsFile { try? FileManager.default.removeItem(at: content.url) }
        if let rendered { try? FileManager.default.removeItem(at: rendered.url) }
    }

    /// The screenshot as exported: the file itself, or a PNG of it with the annotations, at the same DPI.
    private func exportURL() throws -> URL {
        guard let base, !markup.annotations.isEmpty else { return content.url }
        if let rendered, rendered.annotations == markup.annotations { return rendered.url }
        let url = try Screenshot.writePNG(Capture(image: render(base, markup.annotations, scale: sourceScale), scale: sourceScale))
        if let rendered { try? FileManager.default.removeItem(at: rendered.url) }
        rendered = (markup.annotations, url)
        return url
    }

    fileprivate func copyScreenshot(oneX: Bool) {
        guard let url = try? exportURL(), let data = pngData(at: url, dividedBy: oneX ? sourceScale : 1) else { return NSSound.beep() }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let image = NSImage(data: data) { pb.writeObjects([image]) }
        pb.setData(data, forType: .png)
        dismiss()
    }

    fileprivate func copyScreenshotPath(oneX: Bool) {
        do {
            guard let data = pngData(at: try exportURL(), dividedBy: oneX ? sourceScale : 1) else { return NSSound.beep() }
            let url = try writeToScreenshotCache(data)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.path, forType: .string)
            dismiss()
        } catch {
            NSAlert(error: error).beginSheetModal(for: self)
        }
    }

    fileprivate func copyScreenshotText() {
        let index = actions.firstIndex { $0.title == "Copy Text" }!
        Task { [weak self, url = content.url] in
            let text = await recognizeText(at: url)
            guard let self, !self.isDismissing else { return }
            if text.isEmpty { return self.flash("No text found", on: index) }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.dismiss()
        }
    }

    fileprivate func copyRecording() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([content.url as NSURL])
        dismiss()
    }

    fileprivate func revealRecording() {
        NSWorkspace.shared.activateFileViewerSelecting([content.url])
        dismiss()
    }

    fileprivate func trashRecording() {
        do {
            try FileManager.default.trashItem(at: content.url, resultingItemURL: nil)
            dismiss()
        } catch {
            NSAlert(error: error).beginSheetModal(for: self)
        }
    }

    fileprivate func saveScreenshot() {
        guard attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = SaveFolder.current
        panel.nameFieldStringValue = "Screenshot \(timestamp()).png"
        panel.beginSheetModal(for: self) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: try self.exportURL(), to: url)
                self.dismiss()
            } catch {
                NSAlert(error: error).beginSheetModal(for: self)
            }
        }
    }
}

/// The screenshot, drawn with its annotations. Dragging on it drags the file out with the Drag tool, and adds an
/// annotation with any other.
final class MarkupView: NSView, NSDraggingSource {
    private let base: CGImage
    private let scale: CGFloat
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    var tool = MarkupTool.drag { didSet { window?.invalidateCursorRects(for: self) } }
    var onAdd: (Annotation) -> Void = { _ in }
    var fileURL: () -> URL? = { nil }
    private var dragStart: CGPoint?
    private var pending: Annotation? { didSet { needsDisplay = true } }

    init(base: CGImage, scale: CGFloat) {
        self.base = base
        self.scale = scale
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .drag ? .openHand : .crosshair) }

    /// The image fills the view exactly, fitted or in a scroll view, so one factor maps points to pixels.
    private var pixelsPerPoint: CGFloat { CGFloat(base.width) / max(bounds.width, 1) }

    private func pixel(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let k = pixelsPerPoint
        return CGPoint(x: min(max(p.x, 0), bounds.width) * k, y: min(max(p.y, 0), bounds.height) * k)
    }

    override func mouseDown(with event: NSEvent) { dragStart = pixel(event) }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        if tool == .drag {
            self.dragStart = nil
            return dragFile(event)
        }
        autoscroll(with: event)
        pending = tool.annotation(from: dragStart, to: pixel(event), scale: scale)
    }

    override func mouseUp(with event: NSEvent) {
        if let pending { onAdd(pending) }
        pending = nil
        dragStart = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(base, in: bounds)
        ctx.restoreGState()
        let k = pixelsPerPoint
        ctx.scaleBy(x: 1 / k, y: 1 / k)
        Screengrab.draw(annotations + (pending.map { [$0] } ?? []), on: base, in: ctx, scale: scale)
    }
}

extension MarkupView {
    fileprivate func dragFile(_ event: NSEvent) {
        guard let url = fileURL(), let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let fit = min(96 / image.size.width, 96 / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
