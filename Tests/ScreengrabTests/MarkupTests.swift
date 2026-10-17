import CoreGraphics
import Testing
@testable import Screengrab

@Suite struct MarkupTests {
    /// A busy pattern, so averaging any block of it changes its pixels.
    private func pattern(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<h {
            for x in 0..<w {
                let v = CGFloat((x * 37 + y * 101) % 256) / 255
                ctx.setFillColor(CGColor(srgbRed: v, green: 1 - v, blue: CGFloat((x ^ y) & 1), alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    private struct Pixels: Equatable {
        let width: Int
        let bytes: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            self.bytes = bytes
        }

        /// RGBA at (x, y) from the top-left.
        subscript(x: Int, y: Int) -> [UInt8] { Array(bytes[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
    }

    private func isMarkupRed(_ p: [UInt8]) -> Bool { p[0] > 200 && p[1] < 90 && p[2] < 90 }

    @Test func undoAndRedoWalkTheHistory() {
        var markup = Markup()
        let a = Annotation.box(CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = Annotation.arrow(from: .zero, to: CGPoint(x: 20, y: 20))
        markup.add(a)
        markup.add(b)
        markup.undo()
        #expect(markup.annotations == [a])
        markup.redo()
        #expect(markup.annotations == [a, b])
        markup.redo()
        #expect(markup.annotations == [a, b])
        markup.undo()
        markup.undo()
        markup.undo()
        #expect(markup.annotations.isEmpty)
        markup.redo()
        #expect(markup.annotations == [a])
    }

    @Test func addingAfterUndoDropsTheRedo() {
        var markup = Markup()
        let a = Annotation.blur(CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = Annotation.box(CGRect(x: 5, y: 5, width: 10, height: 10))
        markup.add(a)
        markup.undo()
        markup.add(b)
        markup.redo()
        #expect(markup.annotations == [b])
    }

    @Test func clickMakesNothingAndDragsNormalize() {
        let p = CGPoint(x: 50, y: 50)
        for tool in MarkupTool.allCases {
            #expect(tool.annotation(from: p, to: CGPoint(x: 52, y: 51), scale: 2) == nil)
        }
        #expect(MarkupTool.box.annotation(from: p, to: CGPoint(x: 10, y: 20), scale: 2) == .box(CGRect(x: 10, y: 20, width: 40, height: 30)))
        #expect(MarkupTool.blur.annotation(from: p, to: CGPoint(x: 90, y: 52), scale: 1) == nil)
        #expect(MarkupTool.arrow.annotation(from: p, to: CGPoint(x: 50, y: 10), scale: 2) == .arrow(from: p, to: CGPoint(x: 50, y: 10)))
    }

    @Test func noAnnotationsLeavesEveryPixel() {
        let base = pattern(64, 48)
        #expect(Pixels(render(base, [], scale: 2)) == Pixels(base))
    }

    @Test func blurIsBlockUniformInsideAndLeavesTheRestAlone() {
        let base = pattern(120, 90)
        let rect = CGRect(x: 10, y: 20, width: 50, height: 40)
        let before = Pixels(base), after = Pixels(render(base, [.blur(rect)], scale: 1))
        var changed = 0
        for y in 0..<90 {
            for x in 0..<120 {
                guard rect.contains(CGPoint(x: x, y: y)) else {
                    #expect(after[x, y] == before[x, y], "outside (\(x), \(y))")
                    continue
                }
                let blockOrigin = (10 + (x - 10) / 12 * 12, 20 + (y - 20) / 12 * 12)
                #expect(after[x, y] == after[blockOrigin.0, blockOrigin.1], "block at (\(x), \(y))")
                if after[x, y] != before[x, y] { changed += 1 }
            }
        }
        #expect(changed > 50 * 40 * 9 / 10)
    }

    @Test func blockSizeFollowsScale() {
        let base = pattern(100, 100)
        let after = Pixels(render(base, [.blur(CGRect(x: 0, y: 0, width: 100, height: 100))], scale: 2))
        #expect(after[0, 0] == after[23, 23])
        #expect(after[0, 0] != after[24, 0] || after[0, 0] != after[0, 24])
    }

    @Test func arrowDrawsAlongItsLineOnly() {
        let base = pattern(200, 100)
        let from = CGPoint(x: 20, y: 80), to = CGPoint(x: 180, y: 20)
        let before = Pixels(base), after = Pixels(render(base, [.arrow(from: from, to: to)], scale: 1))
        for t in stride(from: 0.05, through: 0.95, by: 0.1) {
            let x = Int(from.x + (to.x - from.x) * t), y = Int(from.y + (to.y - from.y) * t)
            #expect(isMarkupRed(after[x, y]), "on the line at \(t)")
        }
        #expect(after[180, 95] == before[180, 95])
        #expect(after[5, 5] == before[5, 5])
    }

    @Test func boxStrokesItsEdgeAndKeepsItsInside() {
        let base = pattern(100, 100)
        let before = Pixels(base), after = Pixels(render(base, [.box(CGRect(x: 20, y: 20, width: 60, height: 60))], scale: 1))
        #expect(isMarkupRed(after[50, 20]) && isMarkupRed(after[20, 50]) && isMarkupRed(after[80, 50]) && isMarkupRed(after[50, 80]))
        #expect(after[50, 50] == before[50, 50])
    }

    @Test func laterAnnotationsDrawOverBlur() {
        let base = pattern(100, 100)
        let box = Annotation.box(CGRect(x: 20, y: 20, width: 60, height: 60))
        let after = Pixels(render(base, [box, .blur(CGRect(x: 0, y: 0, width: 100, height: 100))], scale: 1))
        #expect(isMarkupRed(after[50, 20]))
    }
}
