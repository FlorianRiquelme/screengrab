import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Screengrab

@Suite struct ScreenshotToolsTests {
    private func blank(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func downscalesPixelSizeByScale() {
        let out = downscaled(blank(401, 200), by: 2)
        #expect(out.width == 201 && out.height == 100)
    }

    @Test func oneXSourceIsUnchanged() {
        let image = blank(120, 80)
        #expect(downscaled(image, by: 1) === image)
    }

    @Test func pngDataDividesPixelSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let rep = NSBitmapImageRep(cgImage: blank(200, 100))
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        let data = try #require(pngData(at: url, dividedBy: 2))
        let out = try #require(NSBitmapImageRep(data: data))
        #expect(out.pixelsWide == 100 && out.pixelsHigh == 50)
        #expect(pngData(at: url) == (try Data(contentsOf: url)))
    }

    @Test func filenameHasNoSpacesAndAvoidsCollisions() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = screenshotFilename(date: date) { _ in false }
        #expect(first.hasPrefix("screenshot-") && first.hasSuffix(".png") && !first.contains(" "))
        let second = screenshotFilename(date: date) { $0 == first }
        #expect(second == first.replacingOccurrences(of: ".png", with: "-2.png"))
        let third = screenshotFilename(date: date) { $0 == first || $0 == second }
        #expect(third == first.replacingOccurrences(of: ".png", with: "-3.png"))
    }
}
