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

func writeToScreenshotCache(_ data: Data) throws -> URL {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Screengrab")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = screenshotFilename(date: Date()) { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    let url = dir.appendingPathComponent(name)
    try data.write(to: url, options: .withoutOverwriting)
    return url
}

func recognizeText(at url: URL) async -> String {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let observations = (try? await request.perform(on: url)) ?? []
    return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}
