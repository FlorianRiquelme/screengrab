import AppKit

/// Maps recorder state and HUD choices onto the HUD, camera bubble, area outline and click ripples.
@MainActor
final class RecordingCoordinator {
    private static let bubbleInset: CGFloat = 24

    private let recorder = Recorder()
    private let hud = RecordingHUD()
    private let bubble = CameraBubble()
    private let outline = AreaOutline()
    private let ripples = ClickRipples()

    var state: RecorderState { recorder.state }
    var onStateChange: ((RecorderState) -> Void)?

    init() {
        recorder.onStateChange = { [weak self] state in self?.stateChanged(state) }
        hud.onOptionsChanged = { [weak self] options in self?.apply(options) }
        hud.onRecord = { [weak self] in self?.record() }
        hud.onClose = { [weak self] in self?.recorder.cancelConfiguring() }
        hud.onStop = { [weak self] in self?.recorder.stop() }
        hud.onToggleMute = { [weak self] in
            guard let self else { return }
            recorder.isMuted.toggle()
            hud.setMuted(recorder.isMuted)
        }
    }

    /// The Cmd+Shift+7 and menu action: open the HUD, close it, or stop recording.
    func toggle() {
        switch recorder.state {
        case .idle:
            let screen = screenUnderMouse()
            let options = RecordingPrefs.load(defaultDisplay: screen.displayID)
            recorder.beginConfiguring()
            hud.show(options: options, on: screen)
            apply(options)
        case .configuring:
            recorder.cancelConfiguring()
        case .recording:
            recorder.stop()
        case .starting, .stopping:
            break
        }
    }

    private func apply(_ options: RecordingOptions) {
        RecordingPrefs.save(options)
        let screen = NSScreen.screen(for: options.target.displayID) ?? screenUnderMouse()
        bubble.setDevice(uniqueID: options.cameraID)
        if options.cameraID != nil { bubble.show(on: screen) } else { bubble.hide() }
        if let rect = options.target.areaRect {
            outline.show(around: screen.cocoaRect(fromDisplay: rect))
        } else {
            outline.hide()
        }
    }

    private func record() {
        let options = hud.options
        if let rect = options.target.areaRect, bubble.isVisible,
           let screen = NSScreen.screen(for: options.target.displayID) {
            let area = screen.cocoaRect(fromDisplay: rect)
            if !area.contains(bubble.frame) {
                bubble.move(to: NSPoint(x: area.minX + Self.bubbleInset, y: area.minY + Self.bubbleInset))
            }
        }
        let excluded = Set([hud.windowNumber, outline.windowNumber].filter { $0 > 0 }.map { CGWindowID($0) })
        recorder.start(options, excludingWindows: excluded)
    }

    private func stateChanged(_ state: RecorderState) {
        switch state {
        case .idle:
            hud.hide()
            outline.hide()
            bubble.hide()
            ripples.stop()
        case .recording(let active):
            hud.showRecording(startedAt: active.startedAt, muted: active.writer.isMuted)
            if let screen = NSScreen.screen(for: active.options.target.displayID) { ripples.start(on: screen) }
        case .configuring, .starting, .stopping:
            break
        }
        onStateChange?(state)
    }
}
