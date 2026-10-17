import AppKit
@preconcurrency import AVFoundation

enum RecordingTarget: Equatable {
    case display(CGDirectDisplayID)
    /// Rect in display points with a top-left origin, as SCStreamConfiguration.sourceRect expects.
    case area(CGDirectDisplayID, CGRect)

    var displayID: CGDirectDisplayID {
        switch self {
        case .display(let id), .area(let id, _): id
        }
    }

    var areaRect: CGRect? {
        if case .area(_, let rect) = self { rect } else { nil }
    }
}

struct RecordingOptions: Equatable {
    var target: RecordingTarget
    var cameraID: String?
    var micID: String?
}

enum CaptureDevices {
    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    static func channelCount(microphoneID: String) -> Int {
        guard let device = AVCaptureDevice(uniqueID: microphoneID),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription),
              asbd.pointee.mChannelsPerFrame > 0 else { return 1 }
        return Int(asbd.pointee.mChannelsPerFrame)
    }
}

/// Last-used options in UserDefaults. A missing key means "default device"; an empty string means "none".
enum RecordingPrefs {
    private static let targetKind = "recording.targetKind"
    private static let areaDisplay = "recording.areaDisplay"
    private static let areaRect = "recording.areaRect"
    private static let camera = "recording.camera"
    private static let microphone = "recording.microphone"

    static func load(defaultDisplay: CGDirectDisplayID) -> RecordingOptions {
        let d = UserDefaults.standard
        var target = RecordingTarget.display(defaultDisplay)
        if d.string(forKey: targetKind) == "area",
           let rect = d.array(forKey: areaRect) as? [Double], rect.count == 4 {
            let id = CGDirectDisplayID(d.integer(forKey: areaDisplay))
            if let screen = NSScreen.screen(for: id), screen.frame.width >= rect[0] + rect[2], screen.frame.height >= rect[1] + rect[3] {
                target = .area(id, CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]))
            }
        }
        return RecordingOptions(
            target: target,
            cameraID: device(forKey: camera, available: CaptureDevices.cameras, fallback: AVCaptureDevice.default(for: .video)),
            micID: device(forKey: microphone, available: CaptureDevices.microphones, fallback: AVCaptureDevice.default(for: .audio)))
    }

    static func save(_ options: RecordingOptions) {
        let d = UserDefaults.standard
        switch options.target {
        case .display:
            d.set("display", forKey: targetKind)
        case .area(let id, let rect):
            d.set("area", forKey: targetKind)
            d.set(Int(id), forKey: areaDisplay)
            d.set([rect.minX, rect.minY, rect.width, rect.height], forKey: areaRect)
        }
        d.set(options.cameraID ?? "", forKey: camera)
        d.set(options.micID ?? "", forKey: microphone)
    }

    private static func device(forKey key: String, available: [AVCaptureDevice], fallback: AVCaptureDevice?) -> String? {
        guard let stored = UserDefaults.standard.string(forKey: key) else { return fallback?.uniqueID }
        if stored.isEmpty { return nil }
        return available.contains { $0.uniqueID == stored } ? stored : fallback?.uniqueID
    }
}
