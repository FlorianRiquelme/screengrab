import AppKit
import ScreenCaptureKit
import VideoToolbox

/// Captures an area while the user scrolls the content under it: frames of the area stream into a Stitcher until
/// Done (Enter) or Cancel (Esc). The outline and the control panel are Screengrab's, so they never appear in frames.
@MainActor
final class ScrollCapture {
    private enum State {
        case selecting(CaptureSelector)
        /// The outline and panel show while the stream starts.
        case starting
        case capturing(Capturing)
        case finishing
        case ended
    }

    private struct Capturing {
        let target: CaptureTarget
        let stream: SCStream
        let scale: CGFloat
    }

    private var state: State
    private let onEnd: (Error?) -> Void
    private let outline = AreaOutline()
    private let panel: ScrollCapturePanel
    private let sink: StitchSink

    static func begin(onEnd: @escaping (Error?) -> Void) -> ScrollCapture {
        weak var capture: ScrollCapture?
        let selector = CaptureSelector.begin(.scrollingCapture) { target in capture?.selected(target) }
        let c = ScrollCapture(selector: selector, onEnd: onEnd)
        capture = c
        return c
    }

    private init(selector: CaptureSelector, onEnd: @escaping (Error?) -> Void) {
        state = .selecting(selector)
        self.onEnd = onEnd
        let panel = ScrollCapturePanel()
        self.panel = panel
        sink = StitchSink(thumbnailWidth: Int(ScrollCapturePanel.thumbnailSize.width * 2)) { [weak panel] in panel?.show($0) }
        panel.onDone = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
    }

    private func selected(_ target: CaptureTarget?) {
        guard case .area(let displayID, let rect)? = target, let screen = NSScreen.screen(for: displayID) else { return end(nil) }
        state = .starting
        let area = screen.cocoaRect(fromDisplay: rect)
        outline.show(around: area)
        panel.show(beside: area, on: screen)
        Task {
            do {
                let filter = try await Screenshot.displayFilter(displayID)
                let scale = CGFloat(filter.pointPixelScale)
                let config = SCStreamConfiguration()
                config.sourceRect = rect
                config.width = Int((rect.width * scale).rounded())
                config.height = Int((rect.height * scale).rounded())
                config.captureResolution = .best
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.showsCursor = false
                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
                try await stream.startCapture()
                guard case .starting = state else {
                    try? await stream.stopCapture()
                    return
                }
                state = .capturing(Capturing(target: .area(displayID: displayID, rect: rect), stream: stream, scale: scale))
            } catch {
                if case .starting = state { end(error) }
            }
        }
    }

    /// Done: the stitched image so far opens in a preview. Does nothing until the stream runs.
    func finish() {
        guard case .capturing(let c) = state else { return }
        state = .finishing
        outline.hide()
        panel.orderOut(nil)
        Task {
            try? await c.stream.stopCapture()
            do {
                // Done right after the stream started can come before its first frame.
                let capture = if let image = await sink.result() { Capture(image: image, scale: c.scale) } else { try await Screenshot.capture(c.target) }
                let url = try Screenshot.writePNG(capture)
                end(nil)
                await PreviewWindow.show(.screenshot(url, ownsFile: true))
            } catch {
                end(error)
            }
        }
    }

    func cancel() {
        switch state {
        case .capturing(let c):
            Task { try? await c.stream.stopCapture() }
        case .starting:
            break // The start task stops the stream once it sees the session ended.
        case .selecting, .finishing, .ended:
            return
        }
        end(nil)
    }

    private func end(_ error: Error?) {
        state = .ended
        outline.hide()
        panel.orderOut(nil)
        onEnd(error)
    }
}

struct StitchProgress {
    let height: Int
    /// Only when it changed and a new one was due.
    let thumbnail: CGImage?
    /// The last frame matched nothing, as after scrolling past the previous frame between two frames.
    let isLost: Bool
}

/// Owns the Stitcher. Everything here runs on `queue`, the stream's sample handler queue, so the Stitcher never
/// crosses threads; the main thread only gets `StitchProgress` copies.
final class StitchSink: NSObject, SCStreamOutput, @unchecked Sendable {
    private static let progressInterval = 0.1
    /// Composing the stitched image copies all of it, so the thumbnail updates less often than the height.
    private static let thumbnailInterval = Duration.milliseconds(400)

    let queue = DispatchQueue(label: "dev.local.screengrab.stitch", qos: .userInitiated)
    private let thumbnailWidth: Int
    private let onProgress: @MainActor (StitchProgress) -> Void
    private var stitcher = Stitcher()
    private var isLost = false
    private var thumbnailStale = false
    private var thumbnailDue = ContinuousClock.now
    private var progressScheduled = false

    init(thumbnailWidth: Int, onProgress: @escaping @MainActor (StitchProgress) -> Void) {
        self.thumbnailWidth = thumbnailWidth
        self.onProgress = onProgress
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, buffer.frameStatus == .complete, let pixels = buffer.imageBuffer else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return }
        switch stitcher.add(image) {
        case .appended:
            isLost = false
            thumbnailStale = true
        case .ignored(.noMatch):
            isLost = true
        case .unchanged, .ignored:
            return
        }
        scheduleProgress()
    }

    /// The stitched image after every frame delivered so far.
    func result() async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.stitcher.image) }
        }
    }

    private func scheduleProgress() {
        guard !progressScheduled else { return }
        progressScheduled = true
        queue.asyncAfter(deadline: .now() + Self.progressInterval) { [self] in
            progressScheduled = false
            var thumbnail: CGImage?
            if thumbnailStale {
                if ContinuousClock.now >= thumbnailDue {
                    thumbnail = makeThumbnail()
                    thumbnailDue = .now + Self.thumbnailInterval
                    thumbnailStale = false
                } else {
                    scheduleProgress()
                }
            }
            let progress = StitchProgress(height: stitcher.height, thumbnail: thumbnail, isLost: isLost)
            DispatchQueue.main.async { [onProgress] in onProgress(progress) }
        }
    }

    private func makeThumbnail() -> CGImage? {
        guard let image = stitcher.image else { return nil }
        let height = max(1, image.height * thumbnailWidth / image.width)
        guard let context = CGContext(data: nil, width: thumbnailWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: Stitcher.bitmapInfo) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailWidth, height: height))
        return context.makeImage()
    }
}

/// Where the control panel goes, in Cocoa coordinates: beside the area and top-aligned with it, right if the screen
/// has room, else left; else centered below or above it; else inside its bottom-right corner.
func controlPanelOrigin(size: CGSize, area: CGRect, visible: CGRect, gap: CGFloat = 12) -> CGPoint {
    let clampX = { (x: CGFloat) in min(max(x, visible.minX), visible.maxX - size.width) }
    let clampY = { (y: CGFloat) in min(max(y, visible.minY), visible.maxY - size.height) }
    let top = clampY(area.maxY - size.height)
    if area.maxX + gap + size.width <= visible.maxX { return CGPoint(x: area.maxX + gap, y: top) }
    if area.minX - gap - size.width >= visible.minX { return CGPoint(x: area.minX - gap - size.width, y: top) }
    let centered = clampX(area.midX - size.width / 2)
    if area.minY - gap - size.height >= visible.minY { return CGPoint(x: centered, y: area.minY - gap - size.height) }
    if area.maxY + gap + size.height <= visible.maxY { return CGPoint(x: centered, y: area.maxY + gap) }
    return CGPoint(x: clampX(area.maxX - gap - size.width), y: clampY(area.minY + gap))
}

/// Non-activating but key, so Enter and Esc reach it while scroll events go to the window under the mouse.
@MainActor
private final class ScrollCapturePanel: NSPanel {
    static let thumbnailSize = CGSize(width: 120, height: 240)

    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    private let thumbnail = NSImageView()
    private let document = FlippedView()
    private let status = NSTextField(labelWithString: "…")

    init() {
        // Titled rather than borderless: a borderless window paints a faint square behind the rounded glass.
        super.init(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        let size = Self.thumbnailSize
        thumbnail.imageScaling = .scaleAxesIndependently
        document.addSubview(thumbnail)
        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.masksToBounds = true
        scrollView.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        scrollView.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: size.height).isActive = true

        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        status.widthAnchor.constraint(equalToConstant: size.width).isActive = true

        let done = button("Done", shortcut: "⏎", action: #selector(donePressed))
        done.bezelColor = .controlAccentColor
        let cancel = button("Cancel", shortcut: "esc", action: #selector(cancelPressed))

        let stack = NSStackView(views: [scrollView, status, done, cancel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(10, after: status)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.contentView = stack
        contentView = glass
        setContentSize(stack.fittingSize)
    }

    private func button(_ title: String, shortcut: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        text.append(NSAttributedString(string: "  \(shortcut)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        b.attributedTitle = text
        b.bezelStyle = .glass
        b.controlSize = .large
        b.widthAnchor.constraint(equalToConstant: Self.thumbnailSize.width).isActive = true
        return b
    }

    func show(beside area: NSRect, on screen: NSScreen) {
        setFrameOrigin(controlPanelOrigin(size: frame.size, area: area, visible: screen.visibleFrame))
        makeKeyAndOrderFront(nil)
    }

    /// The thumbnail fills the width and keeps its newest rows in view.
    func show(_ progress: StitchProgress) {
        status.stringValue = progress.isLost ? "Scroll back up" : "\(progress.height.formatted()) px"
        status.textColor = progress.isLost ? .systemOrange : .secondaryLabelColor
        guard let image = progress.thumbnail else { return }
        let box = Self.thumbnailSize
        let size = NSSize(width: box.width, height: (box.width * CGFloat(image.height) / CGFloat(image.width)).rounded())
        thumbnail.image = NSImage(cgImage: image, size: size)
        thumbnail.frame = NSRect(origin: .zero, size: size)
        document.frame = NSRect(x: 0, y: 0, width: box.width, height: max(size.height, box.height))
        document.scroll(NSPoint(x: 0, y: document.frame.height - box.height))
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onDone?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    @objc private func donePressed() { onDone?() }
    @objc private func cancelPressed() { onCancel?() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
