import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureTarget: Equatable {
    /// Rect in display points with a top-left origin, as SCStreamConfiguration.sourceRect expects.
    case area(displayID: CGDirectDisplayID, rect: CGRect)
    case window(CGWindowID)
}

/// An on-screen window that can be picked, with its frame in global display points (top-left origin).
struct CapturableWindow: Equatable {
    let id: CGWindowID
    let frame: CGRect

    /// Parses a CGWindowList entry, keeping only visible normal windows of other apps. Layer 0 leaves out
    /// the menu bar, the Dock and the desktop.
    init?(info: [String: Any], ownPID: pid_t) {
        guard info[kCGWindowLayer as String] as? Int == 0,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
              info[kCGWindowAlpha as String] as? Double ?? 0 > 0,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width >= 8, frame.height >= 8 else { return nil }
        self.id = id
        self.frame = frame
    }

    /// Front to back. CGWindowList is used because SCShareableContent does not list windows in z-order.
    static func onScreen() -> [CapturableWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { CapturableWindow(info: $0, ownPID: getpid()) }
    }
}

/// A captured image and its pixels per point.
struct Capture {
    let image: CGImage
    let scale: CGFloat
}

enum CaptureError: LocalizedError {
    case targetGone
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .targetGone: "The display or window to capture is no longer available."
        case .writeFailed: "The screenshot could not be written."
        }
    }
}

enum Screenshot {
    /// SCContentFilter.contentRect leaves out the window shadow and nothing reports how far it reaches, so a window
    /// is drawn unscaled into a canvas this much larger on each side and then cropped to its visible pixels.
    private static let shadowRoom: CGFloat = 100

    /// Captures at native pixel resolution. Screengrab's own windows never appear in an area capture.
    static func capture(_ target: CaptureTarget) async throws -> Capture {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        let filter: SCContentFilter
        let size: CGSize
        switch target {
        case .area(let displayID, let rect):
            filter = try await displayFilter(displayID)
            config.sourceRect = rect
            size = rect.size
        case .window(let id):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.targetGone }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.ignoreShadowsSingleWindow = false
            config.shouldBeOpaque = false
            config.backgroundColor = .clear
            config.scalesToFit = false
            size = filter.contentRect.insetBy(dx: -shadowRoom, dy: -shadowRoom).size
        }
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((size.width * scale).rounded())
        config.height = Int((size.height * scale).rounded())
        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if case .window = target { image = image.croppedToVisiblePixels() ?? image }
        return Capture(image: image, scale: scale)
    }

    /// The whole display without Screengrab's own windows.
    static func displayFilter(_ displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.targetGone }
        let own = content.applications.filter { $0.processID == getpid() }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
    }

    /// Writes a PNG to a temporary file, tagged with the DPI that makes it open at point size.
    static func writePNG(_ capture: Capture) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("screengrab-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.writeFailed
        }
        let dpi = 72 * capture.scale
        CGImageDestinationAddImage(dest, capture.image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.writeFailed }
        return url
    }
}

extension CGImage {
    /// Cropped to the bounding box of pixels that are not fully transparent; nil when there are none.
    func croppedToVisiblePixels() -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where rgba[(row + x) * 4 + 3] > 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = y
            }
        }
        guard maxX >= 0 else { return nil }
        return cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}
