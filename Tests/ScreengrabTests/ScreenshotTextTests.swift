import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Screengrab

@Suite struct ScreenshotTextTests {
    private func capture(scale: CGFloat = 1) -> Capture {
        let ctx = CGContext(data: nil, width: Int(1200 * scale), height: Int(320 * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40 * scale, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        for (text, y) in [("SECRET CREDENTIAL", 220), ("PUBLIC MESSAGE", 60)] {
            ctx.textPosition = CGPoint(x: 40 * scale, y: CGFloat(y) * scale)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), ctx)
        }
        return Capture(image: ctx.makeImage()!, scale: scale)
    }

    @Test func recognizesUnmarkedScreenshot() async {
        let text = await recognizeText(in: capture(), annotations: [])
        #expect(text.contains("SECRET CREDENTIAL"))
        #expect(text.contains("PUBLIC MESSAGE"))
    }

    @Test(arguments: [CGFloat(1), CGFloat(2)])
    func excludesBlurredTextAndPreservesVisibleText(scale: CGFloat) async {
        let blur = CGRect(x: 20 * scale, y: 20 * scale, width: 1160 * scale, height: 120 * scale)
        let text = await recognizeText(in: capture(scale: scale), annotations: [.blur(blur)])
        #expect(!text.contains("SECRET CREDENTIAL"))
        #expect(text.contains("PUBLIC MESSAGE"))
    }
}
