import AppKit
import ImageIO
import Vision

func downscaled(_ image: CGImage, by scale: CGFloat) -> CGImage {
    guard scale > 1 else { return image }
    let w = max(1, Int((CGFloat(image.width) / scale).rounded()))
    let h = max(1, Int((CGFloat(image.height) / scale).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? image
}

/// The PNG at `url`, with its pixel size divided by `scale` when that is above 1.
func pngData(at url: URL, dividedBy scale: CGFloat = 1) -> Data? {
    guard scale > 1 else { return try? Data(contentsOf: url) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return NSBitmapImageRep(cgImage: downscaled(image, by: scale)).representation(using: .png, properties: [:])
}

func screenshotFilename(date: Date, exists: (String) -> Bool) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmmss"
    let stem = "screenshot-\(f.string(from: date))"
    var name = "\(stem).png"
    var n = 2
    while exists(name) {
        name = "\(stem)-\(n).png"
        n += 1
    }
    return name
}

/// How long Copy Path files stay in the screenshot cache. The raw value is days; 0 keeps them.
enum CacheRetention: Int, CaseIterable {
    case oneDay = 1, sevenDays = 7, thirtyDays = 30, never = 0

    private static let key = "cacheRetentionDays"

    static var current: CacheRetention {
        get { (UserDefaults.standard.object(forKey: key) as? Int).flatMap(CacheRetention.init) ?? .sevenDays }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var menuTitle: String {
        switch self {
        case .oneDay: "After 1 Day"
        case .never: "Never"
        default: "After \(rawValue) Days"
        }
    }

    /// Completes "Copied screenshots are …".
    var phrase: String {
        switch self {
        case .oneDay: "deleted after 1 day"
        case .never: "kept until you delete them"
        default: "deleted after \(rawValue) days"
        }
    }
}

/// The folder Save opens in: the Desktop until the user picks another in the menu bar menu.
enum SaveFolder {
    private static let key = "saveFolder"

    static let presets = [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory, .picturesDirectory]
        .compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }

    static var current: URL {
        get { UserDefaults.standard.url(forKey: key) ?? presets[0] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var name: String { FileManager.default.displayName(atPath: current.path) }
}

func staleFiles(_ files: [(url: URL, modified: Date)], now: Date, retention: CacheRetention) -> [URL] {
    guard retention != .never else { return [] }
    let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86_400)
    return files.filter { $0.modified < cutoff }.map(\.url)
}

private var screenshotCacheDir: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Screengrab")
}

func writeToScreenshotCache(_ data: Data) throws -> URL {
    let dir = screenshotCacheDir
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = screenshotFilename(date: Date()) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    let url = dir.appendingPathComponent(name)
    try data.write(to: url, options: .withoutOverwriting)
    pruneScreenshotCache()
    return url
}

/// Removes Copy Path files older than the retention. Saved files and recordings live elsewhere and are never touched.
func pruneScreenshotCache() {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(at: screenshotCacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    // Vision keeps its own cache in this directory; only screenshots are ours to delete.
    let files = urls.filter { $0.lastPathComponent.hasPrefix("screenshot-") && $0.pathExtension == "png" }.compactMap { url in
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url: url, modified: $0) }
    }
    for url in staleFiles(files, now: Date(), retention: .current) { try? fm.removeItem(at: url) }
}

func recognizeText(in capture: Capture, annotations: [Annotation]) async -> String {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let image = render(capture.image, annotations, scale: capture.scale)
    let observations = (try? await request.perform(on: image)) ?? []
    return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}
