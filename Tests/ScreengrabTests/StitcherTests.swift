import CoreGraphics
import Foundation
import Testing
@testable import Screengrab

private let width = 240
private let frameHeight = 300

@Suite struct StitcherTests {
    @Test func scrollStepsStitchBackIntoThePage() throws {
        let page = makePage(bands: variedBands(height: 2400, seed: 1))
        var stitcher = Stitcher()
        #expect(stitcher.add(frame(page, top: 0)) == .appended(rows: frameHeight))

        var top = 0
        for step in [4, 31, 90, 170, 1, 60, 240, 7, 120] {
            top += step
            #expect(stitcher.add(frame(page, top: top)) == .appended(rows: step), "step \(step) at \(top)")
            #expect(stitcher.height == top + frameHeight)
        }
        try expectSamePixels(stitcher.image, frame(page, top: 0, height: top + frameHeight))
    }

    @Test func stickyHeaderAndFooterAppearOnce() throws {
        let page = makePage(bands: textBands(height: 1500, seed: 2))
        let header = makePage(bands: [.noise(24), .stripes(8), .noise(16)], seed: 7)
        let footer = makePage(bands: [.stripes(10), .noise(20)], seed: 8)
        let bodyRows = frameHeight - header.height - footer.height
        var stitcher = Stitcher()
        var top = 0
        for step in [0, 25, 100, 180, 3, 60] {
            top += step
            let update = stitcher.add(frame(page, top: top, height: bodyRows, header: header, footer: footer))
            #expect(update == .appended(rows: step == 0 ? frameHeight : step), "step \(step) at \(top)")
        }
        let expected = frame(page, top: 0, height: top + bodyRows, header: header, footer: footer)
        #expect(stitcher.height == expected.height)
        try expectSamePixels(stitcher.image, expected)
    }

    @Test func scrollingUpIsIgnored() throws {
        let page = makePage(bands: variedBands(height: 1200, seed: 3))
        var stitcher = Stitcher()
        _ = stitcher.add(frame(page, top: 0))
        _ = stitcher.add(frame(page, top: 150))
        let before = try #require(stitcher.image)

        #expect(stitcher.add(frame(page, top: 100)) == .ignored(.scrolledUp))
        #expect(stitcher.add(frame(page, top: 20)) == .ignored(.scrolledUp))
        try expectSamePixels(stitcher.image, before)
        #expect(stitcher.add(frame(page, top: 200)) == .appended(rows: 50))
    }

    @Test func duplicateFrameIsUnchanged() throws {
        let page = makePage(bands: variedBands(height: 1200, seed: 4))
        var stitcher = Stitcher()
        _ = stitcher.add(frame(page, top: 0))
        _ = stitcher.add(frame(page, top: 80))
        #expect(stitcher.add(frame(page, top: 80)) == .unchanged)
        #expect(stitcher.height == 380)
        try expectSamePixels(stitcher.image, frame(page, top: 0, height: 380))
    }

    @Test func unrelatedFrameIsIgnored() throws {
        let page = makePage(bands: variedBands(height: 1200, seed: 5))
        let other = makePage(bands: variedBands(height: 1200, seed: 6))
        var stitcher = Stitcher()
        _ = stitcher.add(frame(page, top: 0))
        _ = stitcher.add(frame(page, top: 50))
        #expect(stitcher.add(frame(other, top: 50)) == .ignored(.noMatch))
        #expect(stitcher.add(frame(other, top: 400)) == .ignored(.noMatch))
        try expectSamePixels(stitcher.image, frame(page, top: 0, height: 350))
    }

    @Test func frameOfAnotherSizeIsIgnored() {
        let page = makePage(bands: variedBands(height: 1200, seed: 5))
        var stitcher = Stitcher()
        _ = stitcher.add(frame(page, top: 0))
        #expect(stitcher.add(frame(page, top: 50, height: frameHeight - 1)) == .ignored(.sizeMismatch))
        #expect(stitcher.height == frameHeight)
    }

    @Test func blankBandInsideTheOverlapStillStitches() throws {
        let page = makePage(bands: textBands(height: 600, seed: 9) + [.blank(180)] + textBands(height: 600, seed: 10))
        var stitcher = Stitcher()
        _ = stitcher.add(frame(page, top: 0))
        var top = 0
        for _ in 0..<10 {
            top += 90
            #expect(stitcher.add(frame(page, top: top)) == .appended(rows: 90), "at \(top)")
        }
        try expectSamePixels(stitcher.image, frame(page, top: 0, height: top + frameHeight))
    }

    @Test func blankSpanTallerThanAFrameIsNeverBridgedWrongly() throws {
        let page = makePage(bands: variedBands(height: 500, seed: 11) + [.blank(450)] + variedBands(height: 500, seed: 12))
        var stitcher = Stitcher()
        _ = stitcher.add(frame(page, top: 0))
        var updates: [StitchUpdate] = []
        for top in Swift.stride(from: 100, through: 1100, by: 100) {
            updates.append(stitcher.add(frame(page, top: top)))
        }
        #expect(updates.prefix(4).allSatisfy { $0 == .appended(rows: 100) }, "\(updates)")
        #expect(updates.dropFirst(4).allSatisfy { $0 == .ignored(.noMatch) }, "\(updates)")
        try expectSamePixels(stitcher.image, frame(page, top: 0, height: 700))
    }

    @Test func aChangedCaretInTheOverlapStillMatches() throws {
        let page = makePage(bands: variedBands(height: 1200, seed: 13))
        var stitcher = Stitcher()
        _ = stitcher.add(frame(page, top: 0))
        let withCaret = frame(page, top: 70) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 30, y: frameHeight - 60, width: 2, height: 16))
        }
        #expect(stitcher.add(withCaret) == .appended(rows: 70))
        try expectSamePixels(stitcher.image, frame(page, top: 0, height: 370))
    }

    @Test func offsetFindsTheShiftBetweenSignatures() {
        let page = makePage(bands: textBands(height: 1200, seed: 14))
        let base = FrameSignature(frame(page, top: 300))
        for d in [0, 1, 17, 200, 269] {
            #expect(offset(previous: base, current: FrameSignature(frame(page, top: 300 + d))) == d, "down \(d)")
            #expect(offset(previous: base, current: FrameSignature(frame(page, top: 300 - d))) == -d, "up \(d)")
        }
        let blank = FrameSignature(frame(makePage(bands: [.blank(frameHeight)]), top: 0))
        #expect(offset(previous: blank, current: blank) == 0)
        #expect(offset(previous: base, current: blank) == nil)
        #expect(offset(previous: blank, current: base) == nil)
        let other = FrameSignature(frame(makePage(bands: variedBands(height: 1200, seed: 15)), top: 300))
        #expect(offset(previous: base, current: other) == nil)
    }

    @Test func staticBandsFindHeaderAndFooter() {
        let page = makePage(bands: textBands(height: 1200, seed: 16))
        let header = makePage(bands: [.noise(40)], seed: 17)
        let footer = makePage(bands: [.noise(30)], seed: 18)
        let body = frameHeight - 70
        let a = FrameSignature(frame(page, top: 0, height: body, header: header, footer: footer))
        let b = FrameSignature(frame(page, top: 50, height: body, header: header, footer: footer))
        let bands = staticBands(previous: a, current: b)
        #expect(bands.top == 40 && bands.bottom == 30, "\(bands)")
        #expect(offset(previous: a, current: b) == 50)
    }
}

@Suite struct StitcherBenchmark {
    /// Signature extraction plus offset search for one 2x Retina frame. Run with `scripts/test.sh -c release --filter Benchmark`.
    @Test func matchTimePerRetinaFrame() {
        let page = makePage(width: 1600, bands: variedBands(height: 6000, seed: 20))
        let frames = [0, 300, 1100, 2200, 2800].map { frame(page, top: $0, height: 2000) }
        var signature: [Double] = [], search: [Double] = []
        for (a, b) in zip(frames, frames.dropFirst()) {
            let t0 = Date()
            let p = FrameSignature(a), c = FrameSignature(b)
            let t1 = Date()
            let d = offset(previous: p, current: c)
            let t2 = Date()
            #expect(d != nil && d! > 0)
            signature.append(t1.timeIntervalSince(t0) * 500)
            search.append(t2.timeIntervalSince(t1) * 1000)
        }
        print("per 1600x2000 frame: signature \(signature.map { Int($0) }) ms, offset search \(search.map { Int($0) }) ms")
    }
}

// MARK: - Synthetic pages

enum Band {
    case noise(Int)
    case stripes(Int)
    case blank(Int)
    case gradient(Int)
}

/// Random text-like noise, stripes, blank bands and gradients adding up to `height` rows.
func variedBands(height: Int, seed: UInt64) -> [Band] {
    randomBands(height: height, seed: seed, kinds: [Band.noise, Band.stripes, Band.blank, Band.gradient])
}

/// Only text-like noise and stripes: every row carries content, like a page of text.
func textBands(height: Int, seed: UInt64) -> [Band] {
    randomBands(height: height, seed: seed, kinds: [Band.noise, Band.stripes])
}

private func randomBands(height: Int, seed: UInt64, kinds: [(Int) -> Band]) -> [Band] {
    var rng = SplitMix64(seed: seed)
    var bands: [Band] = [], total = 0
    while total < height {
        let h = min(height - total, 16 + Int(rng.next() % 48))
        bands.append(kinds[Int(rng.next() % UInt64(kinds.count))](h))
        total += h
    }
    return bands
}

func makePage(width: Int = width, bands: [Band], seed: UInt64 = 1) -> CGImage {
    var rng = SplitMix64(seed: seed)
    let height = bands.reduce(0) { $0 + $1.height }
    var pixels = [UInt32](repeating: 0xFFFF_FFFF, count: width * height)
    var y = 0
    for band in bands {
        let rows = y..<(y + band.height)
        switch band {
        case .noise:
            for i in rows.lowerBound * width..<rows.upperBound * width where rng.next() % 4 == 0 {
                pixels[i] = 0xFF00_0000 | UInt32(rng.next() & 0x5F5F_5F)
            }
        case .stripes:
            let a = 0xFF00_0000 | UInt32(rng.next() & 0xFFFF_FF), b = 0xFF00_0000 | UInt32(rng.next() & 0xFFFF_FF)
            for r in rows { pixels.replaceSubrange(r * width..<(r + 1) * width, with: repeatElement((r / 2) % 2 == 0 ? a : b, count: width)) }
        case .blank:
            break
        case .gradient:
            for r in rows {
                let v = UInt32(255 - (r - rows.lowerBound) * 120 / band.height)
                pixels.replaceSubrange(r * width..<(r + 1) * width, with: repeatElement(0xFF00_0000 | v << 16 | v << 8 | v, count: width))
            }
        }
        y = rows.upperBound
    }
    return pixels.withUnsafeMutableBytes { bytes in
        CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bgra)!.makeImage()!
    }
}

/// `height` page rows from `top` between an optional header and footer, drawn into a fresh image like a capture.
func frame(_ page: CGImage, top: Int, height: Int = frameHeight, header: CGImage? = nil, footer: CGImage? = nil,
           decorate: ((CGContext) -> Void)? = nil) -> CGImage {
    let total = height + (header?.height ?? 0) + (footer?.height ?? 0)
    let context = CGContext(data: nil, width: page.width, height: total, bitsPerComponent: 8, bytesPerRow: page.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bgra)!
    context.interpolationQuality = .none
    let body = page.cropping(to: CGRect(x: 0, y: top, width: page.width, height: height))!
    context.draw(body, in: CGRect(x: 0, y: footer?.height ?? 0, width: page.width, height: height))
    if let header { context.draw(header, in: CGRect(x: 0, y: total - header.height, width: page.width, height: header.height)) }
    if let footer { context.draw(footer, in: CGRect(x: 0, y: 0, width: page.width, height: footer.height)) }
    decorate?(context)
    return context.makeImage()!
}

func expectSamePixels(_ image: CGImage?, _ expected: CGImage, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let image = try #require(image, sourceLocation: sourceLocation)
    #expect(image.width == expected.width && image.height == expected.height,
            "\(image.width)x\(image.height) vs \(expected.width)x\(expected.height)", sourceLocation: sourceLocation)
    guard image.width == expected.width, image.height == expected.height else { return }
    let a = bgraBytes(image), b = bgraBytes(expected)
    let stride = image.width * 4
    let badRow = (0..<image.height).first { a[$0 * stride..<($0 + 1) * stride] != b[$0 * stride..<($0 + 1) * stride] }
    #expect(badRow == nil, "first differing row \(badRow ?? -1) of \(image.height)", sourceLocation: sourceLocation)
}

private func bgraBytes(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bgra)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

private let bgra = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

extension Band {
    var height: Int {
        switch self {
        case .noise(let h), .stripes(let h), .blank(let h), .gradient(let h): h
        }
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
