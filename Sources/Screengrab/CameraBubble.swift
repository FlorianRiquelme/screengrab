import AppKit
@preconcurrency import AVFoundation

@MainActor
final class CameraBubble {
    private static let diameter: CGFloat = 220
    private static let margin: CGFloat = 32

    private let panel: NSPanel
    private let session = AVCaptureSession()
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let sessionQueue = DispatchQueue(label: "screengrab.camera")
    private var deviceID: String?
    private var shouldRun = false

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        let d = Self.diameter
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: d, height: d),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = CGRect(x: 0, y: 0, width: d, height: d)
        previewLayer.cornerRadius = d / 2
        previewLayer.masksToBounds = true
        previewLayer.borderWidth = 2
        previewLayer.borderColor = NSColor.white.cgColor

        let view = NSView(frame: NSRect(x: 0, y: 0, width: d, height: d))
        view.wantsLayer = true
        view.layer?.addSublayer(previewLayer)
        panel.contentView = view
    }

    func setDevice(uniqueID: String?) {
        deviceID = uniqueID
        applySession()
    }

    /// Keeps the user's placement when the bubble is already on the target screen.
    func show(on screen: NSScreen) {
        if !panel.frame.intersects(screen.frame) {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.minX + Self.margin, y: v.minY + Self.margin))
        }
        panel.orderFrontRegardless()
        shouldRun = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            Task { @MainActor in self?.applySession() }
        }
    }

    func move(to origin: NSPoint) {
        panel.setFrameOrigin(origin)
    }

    func hide() {
        panel.orderOut(nil)
        shouldRun = false
        applySession()
    }

    private func applySession() {
        let run = shouldRun && deviceID != nil && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let deviceID = deviceID
        let session = session
        sessionQueue.async { [weak self] in
            let current = (session.inputs.first as? AVCaptureDeviceInput)?.device.uniqueID
            if current != deviceID {
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID),
                   let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
                Task { @MainActor [weak self] in self?.mirrorPreview() }
            }
            if run && !session.inputs.isEmpty {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func mirrorPreview() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}
