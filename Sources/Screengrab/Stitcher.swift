import CoreGraphics
import Foundation

/// What `Stitcher.add` did with a frame.
enum StitchUpdate: Equatable {
    /// The content scrolled down by `rows`; the frame's new rows were added.
    case appended(rows: Int)
    case unchanged
    case ignored(Reason)

    enum Reason: Equatable {
        case scrolledUp
        case noMatch
        case sizeMismatch
    }
}

/// Builds one tall image from same-sized frames of an area whose content scrolls down.
/// Frames that scroll up or do not match confidently are ignored, so the result never corrupts.
/// Rows that stay put at the top and bottom of every frame (toolbars, sticky bars) appear once.
struct Stitcher {
    private var width = 0
    private var frameHeight = 0
    private var stride = 0
    private var colorSpace = CGColorSpaceCreateDeviceRGB()
    /// Stitched rows above the footer, BGRA, top to bottom. Page row 0 is the first frame's top row.
    private var body = Data()
    private var bodyRows = 0
    /// The last accepted frame and the page row its top shows.
    private var previous: (signature: FrameSignature, image: CGImage, origin: Int)?
    /// Static rows at the bottom of `previous`; drawn once, below the body.
    private var footer = 0

    /// BGRA, the layout capture frames come in.
    static let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

    /// Height of `image` in pixels. Cheap, for live progress.
    var height: Int { bodyRows + footer }

    /// The stitched result, composed on each access.
    var image: CGImage? {
        guard let previous else { return nil }
        let total = bodyRows + footer
        guard let context = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: stride,
                                      space: colorSpace, bitmapInfo: Self.bitmapInfo) else { return nil }
        body.withUnsafeBytes { context.data!.copyMemory(from: $0.baseAddress!, byteCount: bodyRows * stride) }
        if footer > 0, let strip = previous.image.cropping(to: CGRect(x: 0, y: frameHeight - footer, width: width, height: footer)) {
            context.interpolationQuality = .none
            context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: footer))
        }
        return context.makeImage()
    }

    mutating func add(_ frame: CGImage) -> StitchUpdate {
        guard let previous else {
            start(with: frame)
            return .appended(rows: frame.height)
        }
        guard frame.width == width, frame.height == frameHeight else { return .ignored(.sizeMismatch) }
        let current = FrameSignature(frame)
        let bands = staticBands(previous: previous.signature, current: current)
        guard let shift = offset(previous: previous.signature, current: current, bands: bands) else { return .ignored(.noMatch) }
        if shift == 0 { return .unchanged }
        if shift < 0 { return .ignored(.scrolledUp) }

        // The body always ends where the previous frame's content ends under the current footer estimate:
        // a taller footer trims rows this frame shows again higher up, a shorter one reclaims rows it hid.
        let previousEnd = previous.origin + frameHeight - bands.bottom
        if previousEnd < bodyRows {
            bodyRows = previousEnd
            body.count = bodyRows * stride
        } else if previousEnd > bodyRows {
            append(previous.image, rows: (bodyRows - previous.origin)..<(frameHeight - bands.bottom))
        }
        let origin = previous.origin + shift
        append(frame, rows: (bodyRows - origin)..<(frameHeight - bands.bottom))
        footer = bands.bottom
        self.previous = (current, frame, origin)
        return .appended(rows: shift)
    }

    private mutating func start(with frame: CGImage) {
        width = frame.width
        frameHeight = frame.height
        stride = width * 4
        colorSpace = frame.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        append(frame, rows: 0..<frameHeight)
        previous = (FrameSignature(frame), frame, 0)
    }

    private mutating func append(_ image: CGImage, rows: Range<Int>) {
        guard !rows.isEmpty,
              let strip = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: width, height: rows.count)) else { return }
        let offset = body.count
        body.count += rows.count * stride
        body.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress! + offset, width: width, height: rows.count, bitsPerComponent: 8,
                                          bytesPerRow: stride, space: colorSpace, bitmapInfo: Self.bitmapInfo) else { return }
            context.interpolationQuality = .none
            context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: rows.count))
        }
        bodyRows += rows.count
    }
}

// MARK: - Matching

/// Per-row content summary of a frame: mean luminance in `bins` horizontal bins.
struct FrameSignature {
    static let maxBins = 64

    let rows: Int
    let bins: Int
    let luma: [UInt8]
    /// Rows that differ from the row below them. Only these can tell offsets apart.
    let isActive: [Bool]
    let activeRows: [Int]

    init(_ image: CGImage) {
        rows = image.height
        bins = min(Self.maxBins, image.width)
        luma = Self.binnedLuma(of: image, bins: bins)
        let active = Self.activeRows(luma: luma, rows: rows, bins: bins)
        isActive = active
        activeRows = active.indices.filter { active[$0] }
    }

    /// Blits into BGRA and sums luminance per bin. A gray context would be simpler, but CoreGraphics
    /// converts a fresh image to gray at ~12 ms per 1600x2000 frame; this path takes ~2 ms.
    private static func binnedLuma(of image: CGImage, bins: Int) -> [UInt8] {
        let width = image.width, rows = image.height
        var luma = [UInt8](repeating: 0, count: rows * bins)
        guard let context = CGContext(data: nil, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: Stitcher.bitmapInfo),
              let data = context.data else { return luma }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: rows))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        let edges = (0...bins).map { $0 * width / bins }
        luma.withUnsafeMutableBufferPointer { out in
            for r in 0..<rows {
                let row = pixels + r * stride
                for b in 0..<bins {
                    var sum = 0
                    for x in edges[b]..<edges[b + 1] {
                        let p = row + x * 4
                        sum += (Int(p[0]) + 2 * Int(p[1]) + Int(p[2])) >> 2
                    }
                    out[r * bins + b] = UInt8(sum / (edges[b + 1] - edges[b]))
                }
            }
        }
        return luma
    }

    private static func activeRows(luma: [UInt8], rows: Int, bins: Int) -> [Bool] {
        var active = [Bool](repeating: false, count: rows)
        luma.withUnsafeBufferPointer { l in
            for r in 0..<max(rows - 1, 0) {
                active[r] = maxDiff(l.baseAddress! + r * bins, l.baseAddress! + (r + 1) * bins, bins) >= activeThreshold
            }
        }
        return active
    }
}

/// Two rows show the same content when their mean bin difference stays under this; a caret or a few changed pixels do.
private let matchThreshold = 4
/// A row is content when some bin changes at least this much to the next row: a rule, a glyph edge, a box border.
private let activeThreshold = 16
/// Fewer content rows than this in an overlap can line up by chance, so blank overlaps never match.
private let minActiveRows = 8
/// A hover or a blinking caret changes a few rows; a wrong offset mismatches most content rows.
private let matchedShare = 0.9
/// Rows sampled per candidate offset in the coarse pass, and coarse winners re-checked on every overlap row.
private let coarseSamples = 32
private let candidates = 12

/// Rows at the top and bottom that stayed put between the frames, such as a toolbar or a sticky footer.
/// Blank content that happens to sit at the same rows in both frames counts too: it only narrows the
/// search band, while a plain toolbar taken for content would mismatch or repeat.
func staticBands(previous: FrameSignature, current: FrameSignature) -> (top: Int, bottom: Int) {
    guard previous.rows == current.rows, previous.bins == current.bins else { return (0, 0) }
    let rows = current.rows, bins = current.bins
    return previous.luma.withUnsafeBufferPointer { p in
        current.luma.withUnsafeBufferPointer { c in
            let same = { (r: Int) in rowDiff(p.baseAddress! + r * bins, c.baseAddress! + r * bins, bins) <= matchThreshold * bins }
            var top = 0
            while top < rows, same(top) { top += 1 }
            var bottom = 0
            while bottom < rows - top, same(rows - 1 - bottom) { bottom += 1 }
            return (top, bottom)
        }
    }
}

/// How far the content scrolled down from `previous` to `current`: 0 when unchanged, negative when it
/// scrolled up, nil when no offset matches confidently.
func offset(previous: FrameSignature, current: FrameSignature) -> Int? {
    offset(previous: previous, current: current, bands: staticBands(previous: previous, current: current))
}

func offset(previous: FrameSignature, current: FrameSignature, bands: (top: Int, bottom: Int)) -> Int? {
    guard previous.rows == current.rows, previous.bins == current.bins, current.rows > 0 else { return nil }
    return previous.luma.withUnsafeBufferPointer { pl in
        current.luma.withUnsafeBufferPointer { cl in
            let p = Rows(previous, pl.baseAddress!), c = Rows(current, cl.baseAddress!)
            let whole = compare(p, c, offset: 0, rows: 0..<c.count)
            if whole.matched >= share(whole.rows), whole.activeMatched >= share(whole.active) { return 0 }
            if let d = scrollDown(from: p, to: c, top: bands.top, bottom: bands.bottom) { return d }
            if let d = scrollDown(from: c, to: p, top: bands.top, bottom: bands.bottom) { return -d }
            return nil
        }
    }
}

private struct Rows {
    let base: UnsafePointer<UInt8>
    let bins: Int
    let count: Int
    let isActive: [Bool]
    let activeRows: [Int]

    init(_ signature: FrameSignature, _ base: UnsafePointer<UInt8>) {
        self.base = base
        bins = signature.bins
        count = signature.rows
        isActive = signature.isActive
        activeRows = signature.activeRows
    }

    subscript(r: Int) -> UnsafePointer<UInt8> { base + r * bins }
}

private struct RowMatch {
    var rows = 0, matched = 0, active = 0, activeMatched = 0, diff = 0
}

private func share(_ n: Int) -> Int { Int((Double(n) * matchedShare).rounded(.up)) }

/// Compares current rows in `rows` with the previous rows `offset` further down.
private func compare(_ p: Rows, _ c: Rows, offset d: Int, rows: Range<Int>) -> RowMatch {
    var m = RowMatch(rows: rows.count)
    for r in rows {
        let diff = rowDiff(c[r], p[r + d], c.bins)
        let same = diff <= matchThreshold * c.bins
        m.diff += diff
        if same { m.matched += 1 }
        if c.isActive[r] || p.isActive[r + d] {
            m.active += 1
            if same { m.activeMatched += 1 }
        }
    }
    return m
}

/// The downward scroll from `p` to `c`, scored on the rows between the static top and bottom bands.
private func scrollDown(from p: Rows, to c: Rows, top: Int, bottom: Int) -> Int? {
    let end = c.count - bottom
    // Scrolls up to 90% of the frame are accepted; the content-row minimum below rejects what is left to score.
    let maxOffset = c.count - max(24, c.count / 10)
    guard maxOffset >= 1, end - top > 0 else { return nil }

    // Coarse pass: score every offset on a spread of the current frame's content rows inside the overlap.
    let active = c.activeRows.filter { $0 >= top && $0 < end }
    var scored: [(d: Int, score: Int)] = []
    var inOverlap = active.count
    for d in 1...maxOffset {
        while inOverlap > 0, active[inOverlap - 1] >= end - d { inOverlap -= 1 }
        guard inOverlap >= minActiveRows else { break }
        let step = max(1, inOverlap / coarseSamples)
        var sum = 0, n = 0
        for i in Swift.stride(from: 0, to: inOverlap, by: step) {
            sum += rowDiff(c[active[i]], p[active[i] + d], c.bins)
            n += 1
        }
        scored.append((d, sum / n))
    }
    scored.sort { ($0.score, $0.d) < ($1.score, $1.d) }

    // Fine pass: check the best coarse offsets on every overlap row; the lowest mean difference wins.
    var best: (mean: Int, d: Int)?
    for candidate in scored.prefix(candidates) {
        let m = compare(p, c, offset: candidate.d, rows: top..<(end - candidate.d))
        guard m.active >= minActiveRows, m.activeMatched >= share(m.active) else { continue }
        let result = (m.diff / m.rows, candidate.d)
        if best == nil || result < best! { best = result }
    }
    return best?.d
}

@inline(__always)
private func rowDiff(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int) -> Int {
    var sum = 0
    for i in 0..<n { sum += abs(Int(a[i]) - Int(b[i])) }
    return sum
}

@inline(__always)
private func maxDiff(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int) -> Int {
    var m = 0
    for i in 0..<n { m = max(m, abs(Int(a[i]) - Int(b[i]))) }
    return m
}
