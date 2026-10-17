import CoreGraphics
import Testing
@testable import Screengrab

@Suite struct CropTests {
    /// A 100x100 transparent image with an opaque 30x10 block whose top-left pixel is at (20, 10), top-left origin.
    private func imageWithBlock() throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 100 - 10 - 10, width: 30, height: 10))
        return try #require(ctx.makeImage())
    }

    @Test func cropsToTheVisibleBlock() throws {
        let cropped = try #require(try imageWithBlock().croppedToVisiblePixels())
        #expect(cropped.width == 30)
        #expect(cropped.height == 10)
        let alpha = try opaqueFraction(cropped)
        #expect(alpha == 1, "crop lands on the block, not its vertical mirror")
    }

    @Test func fullyTransparentImageHasNoCrop() throws {
        let ctx = try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        #expect(try #require(ctx.makeImage()).croppedToVisiblePixels() == nil)
    }

    private func opaqueFraction(_ image: CGImage) throws -> Double {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = try #require(CGContext(data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let alpha = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        return Double(alpha.filter { $0 == 255 }.count) / Double(alpha.count)
    }
}
