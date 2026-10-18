import AppKit
@preconcurrency import AVFoundation

/// Floating bar at the bottom of the screen: a configuration form before recording,
/// a compact timer/mute/stop bar while recording.
@MainActor
final class RecordingHUD: NSPanel {
    private(set) var options: RecordingOptions
    var onOptionsChanged: ((RecordingOptions) -> Void)?
    var onRecord: (() -> Void)?
    var onClose: (() -> Void)?
    var onStop: (() -> Void)?
    var onToggleMute: (() -> Void)?

    private let glass = NSGlassEffectView()
    private let configStack = NSStackView()
    private let recordingStack = NSStackView()
    private let targetControl = NSSegmentedControl(labels: ["Screen", "Area"], trackingMode: .selectOne, target: nil, action: nil)
    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cameraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let micPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let muteButton = NSButton()
    private let recordButton = NSButton()
    private var selector: CaptureSelector?
    private var timer: Timer?
    private var startedAt = Date()
    private var isRecording = false

    init() {
        options = RecordingOptions(target: .display(0))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        glass.contentView = NSView()
        contentView = glass

        buildConfigStack()
        buildRecordingStack()
        for stack in [configStack, recordingStack] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.edgeInsets = NSEdgeInsets(top: 9, left: 9, bottom: 9, right: 9)
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
    }

    /// Only the active stack lives in the view hierarchy; a hidden stack's edge constraints would still size the panel.
    private func install(_ stack: NSStackView) {
        guard let background = glass.contentView, stack.superview !== background else { return }
        background.subviews.forEach { $0.removeFromSuperview() }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    override var canBecomeKey: Bool { true }

    func show(options: RecordingOptions, on screen: NSScreen) {
        self.options = options
        isRecording = false
        reloadDevices()
        syncControls()
        install(configStack)
        present(on: screen)
        makeKeyAndOrderFront(nil)
        Tips.show(.recordingBar, [
            Tip(anchor: targetControl, text: "Record a whole display or an area."),
            Tip(anchor: cameraPopup, text: "The camera bubble and click ripples are part of the video. This bar is not."),
            Tip(anchor: recordButton, text: "Press Return or click Record. Press \(shortcut(for: .toggleRecording)) again to stop."),
        ])
    }

    func showRecording(startedAt: Date, muted: Bool) {
        Tips.dismiss(in: self)
        isRecording = true
        self.startedAt = startedAt
        install(recordingStack)
        muteButton.isEnabled = options.micID != nil
        setMuted(muted)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTime() }
        }
        updateTime()
        present(on: screen ?? screenUnderMouse())
    }

    func setMuted(_ muted: Bool) {
        muteButton.image = symbol(muted ? "mic.slash.fill" : "mic.fill", color: muted ? .systemRed : .labelColor)
        muteButton.setAccessibilityLabel(muted ? "Unmute" : "Mute")
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        selector?.dismiss()
        selector = nil
        Tips.dismiss(in: self)
        orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch (event.keyCode, isRecording) {
        case (53, false): onClose?()
        case (36, false), (76, false): onRecord?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if !isRecording { onClose?() }
    }

    private func present(on screen: NSScreen) {
        let size = (isRecording ? recordingStack : configStack).fittingSize
        setContentSize(size)
        glass.cornerRadius = size.height / 2
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: (v.midX - size.width / 2).rounded(), y: v.minY + 24))
    }

    private func buildConfigStack() {
        targetControl.controlSize = .large
        targetControl.target = self
        targetControl.action = #selector(targetChanged)
        displayPopup.target = self
        displayPopup.action = #selector(displayChanged)
        cameraPopup.target = self
        cameraPopup.action = #selector(cameraChanged)
        micPopup.target = self
        micPopup.action = #selector(micChanged)
        for popup in [displayPopup, cameraPopup, micPopup] {
            popup.bezelStyle = .glass
            popup.controlSize = .large
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
        }

        let record = recordButton
        record.title = "Record"
        record.image = symbol("record.circle", color: .white)
        record.target = self
        record.action = #selector(recordPressed)
        record.imagePosition = .imageLeading
        record.bezelStyle = .glass
        record.bezelColor = .systemRed
        record.controlSize = .large
        let close = NSButton(image: symbol("xmark", color: .labelColor), target: self, action: #selector(closePressed))
        close.bezelStyle = .glass
        close.borderShape = .circle
        close.controlSize = .large

        configStack.spacing = 8
        configStack.addArrangedSubview(targetControl)
        configStack.addArrangedSubview(displayPopup)
        configStack.addArrangedSubview(divider())
        configStack.addArrangedSubview(icon("web.camera"))
        configStack.addArrangedSubview(cameraPopup)
        configStack.addArrangedSubview(icon("mic"))
        configStack.addArrangedSubview(micPopup)
        configStack.addArrangedSubview(divider())
        configStack.addArrangedSubview(record)
        configStack.addArrangedSubview(close)
        configStack.setCustomSpacing(2, after: configStack.arrangedSubviews[3])
        configStack.setCustomSpacing(2, after: configStack.arrangedSubviews[5])
        configStack.setCustomSpacing(14, after: configStack.arrangedSubviews[2])
        configStack.setCustomSpacing(14, after: configStack.arrangedSubviews[7])
    }

    private func buildRecordingStack() {
        let dot = NSImageView(image: symbol("circle.fill", color: .systemRed))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        timeLabel.textColor = .labelColor
        muteButton.bezelStyle = .glass
        muteButton.borderShape = .circle
        muteButton.controlSize = .large
        muteButton.target = self
        muteButton.action = #selector(mutePressed)
        setMuted(false)
        let stop = NSButton(title: "Stop", image: symbol("stop.fill", color: .labelColor), target: self, action: #selector(stopPressed))
        stop.imagePosition = .imageLeading
        stop.bezelStyle = .glass
        stop.controlSize = .large

        recordingStack.spacing = 10
        recordingStack.addArrangedSubview(dot)
        recordingStack.addArrangedSubview(timeLabel)
        recordingStack.addArrangedSubview(divider())
        recordingStack.addArrangedSubview(muteButton)
        recordingStack.addArrangedSubview(stop)
        recordingStack.setCustomSpacing(6, after: dot)
        muteButton.heightAnchor.constraint(equalTo: stop.heightAnchor).isActive = true
        muteButton.widthAnchor.constraint(equalTo: muteButton.heightAnchor).isActive = true
    }

    private func reloadDevices() {
        fill(displayPopup, none: nil, items: NSScreen.screens.map { ($0.localizedName, String($0.displayID)) })
        fill(cameraPopup, none: "No Camera", items: CaptureDevices.cameras.map { ($0.localizedName, $0.uniqueID) })
        fill(micPopup, none: "No Microphone", items: CaptureDevices.microphones.map { ($0.localizedName, $0.uniqueID) })
    }

    private func fill(_ popup: NSPopUpButton, none: String?, items: [(String, String)]) {
        popup.removeAllItems()
        if let none {
            popup.addItem(withTitle: none)
            popup.menu?.addItem(.separator())
        }
        for (title, id) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = id
        }
    }

    private func syncControls() {
        targetControl.selectedSegment = options.target.areaRect == nil ? 0 : 1
        displayPopup.isHidden = NSScreen.screens.count < 2 || options.target.areaRect != nil
        select(displayPopup, id: String(options.target.displayID))
        select(cameraPopup, id: options.cameraID)
        select(micPopup, id: options.micID)
    }

    private func select(_ popup: NSPopUpButton, id: String?) {
        let index = popup.itemArray.firstIndex { ($0.representedObject as? String) == id } ?? 0
        popup.selectItem(at: index)
    }

    private func selectedID(_ popup: NSPopUpButton) -> String? {
        popup.selectedItem?.representedObject as? String
    }

    private func update(_ change: (inout RecordingOptions) -> Void) {
        change(&options)
        syncControls()
        if !isRecording { present(on: screen ?? screenUnderMouse()) }
        onOptionsChanged?(options)
    }

    private func updateTime() {
        let s = Int(Date().timeIntervalSince(startedAt))
        timeLabel.stringValue = String(format: "%02d:%02d", s / 60, s % 60)
    }

    @objc private func targetChanged() {
        if targetControl.selectedSegment == 0 {
            update { $0.target = .display($0.target.displayID) }
            return
        }
        let previous = options.target
        let screen = NSScreen.screen(for: previous.displayID) ?? screenUnderMouse()
        selector = CaptureSelector.begin(.recordingArea(on: screen)) { [weak self] target in
            guard let self else { return }
            selector = nil
            if case .area(let id, let rect)? = target { update { $0.target = .area(id, rect) } } else { update { $0.target = previous } }
            makeKeyAndOrderFront(nil)
        }
    }

    @objc private func displayChanged() {
        guard let id = selectedID(displayPopup).flatMap(UInt32.init) else { return }
        update { $0.target = .display(id) }
    }

    @objc private func cameraChanged() { update { $0.cameraID = selectedID(cameraPopup) } }
    @objc private func micChanged() { update { $0.micID = selectedID(micPopup) } }
    @objc private func recordPressed() { onRecord?() }
    @objc private func closePressed() { onClose?() }
    @objc private func stopPressed() { onStop?() }
    @objc private func mutePressed() { onToggleMute?() }

    private func symbol(_ name: String, color: NSColor) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [color])))!
        image.isTemplate = false
        return image
    }

    private func icon(_ name: String) -> NSImageView {
        let view = NSImageView(image: symbol(name, color: .secondaryLabelColor))
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return box
    }
}
