import AppKit

/// In image pixels with a top-left origin.
enum Annotation: Equatable {
    case arrow(from: CGPoint, to: CGPoint)
    case box(CGRect)
    case blur(CGRect)
}

struct Markup {
    private(set) var annotations: [Annotation] = []
    private(set) var redoStack: [Annotation] = []

    mutating func add(_ annotation: Annotation) {
        annotations.append(annotation)
        redoStack.removeAll()
    }

    mutating func undo() {
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
    }

    mutating func redo() {
        guard let last = redoStack.popLast() else { return }
        annotations.append(last)
    }
}

/// `drag` drags the screenshot file out instead of drawing; it is the default.
enum MarkupTool: CaseIterable {
    case drag, arrow, box, blur

    var title: String {
        switch self {
        case .drag: "Drag"
        case .arrow: "Arrow"
        case .box: "Box"
        case .blur: "Blur"
        }
    }

    var symbol: String {
        switch self {
        case .drag: "hand.point.up.left"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .blur: "checkerboard.rectangle"
        }
    }

    var key: String {
        switch self {
        case .drag: "d"
        case .arrow: "a"
        case .box: "r"
        case .blur: "b"
        }
    }

    /// The annotation a drag from `a` to `b` makes, or nil when it is too short to be meant (a click).
    func annotation(from a: CGPoint, to b: CGPoint, scale: CGFloat) -> Annotation? {
        let min = 6 * scale
        switch self {
        case .drag:
            return nil
        case .arrow:
            return hypot(b.x - a.x, b.y - a.y) >= min ? .arrow(from: a, to: b) : nil
        case .box, .blur:
            let rect = CGRect(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            guard rect.width >= min, rect.height >= min else { return nil }
            return self == .box ? .box(rect) : .blur(rect)
        }
    }
}

/// `base` with `annotations` drawn on it at its own pixel size; `scale` is its pixels per point.
func render(_ base: CGImage, _ annotations: [Annotation], scale: CGFloat) -> CGImage {
    guard !annotations.isEmpty,
          let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
    let size = CGSize(width: base.width, height: base.height)
    ctx.draw(base, in: CGRect(origin: .zero, size: size))
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    draw(annotations, on: base, in: ctx, scale: scale)
    return ctx.makeImage() ?? base
}

/// Draws into a context whose user space is `base`'s pixels with a top-left origin. Blurs go first so a box
/// or arrow drawn over a redacted area stays visible.
func draw(_ annotations: [Annotation], on base: CGImage, in ctx: CGContext, scale: CGFloat) {
    for case .blur(let rect) in annotations { pixelate(rect, of: base, in: ctx, scale: scale) }
    let lineWidth = 3 * scale
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 3 * scale, color: CGColor(gray: 0, alpha: 0.45))
    ctx.setStrokeColor(markupColor)
    ctx.setFillColor(markupColor)
    ctx.setLineWidth(lineWidth)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    for annotation in annotations {
        switch annotation {
        case .arrow(let from, let to):
            // One transparency layer per arrow so the shaft and head cast a single shadow.
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawArrow(from: from, to: to, lineWidth: lineWidth, in: ctx)
            ctx.endTransparencyLayer()
        case .box(let rect):
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2 * scale, cornerHeight: 2 * scale, transform: nil))
            ctx.strokePath()
        case .blur:
            break
        }
    }
    ctx.restoreGState()
}

private let markupColor = CGColor(srgbRed: 1, green: 0.2, blue: 0.17, alpha: 1)

private func drawArrow(from: CGPoint, to: CGPoint, lineWidth: CGFloat, in ctx: CGContext) {
    let length = hypot(to.x - from.x, to.y - from.y)
    guard length > 0 else { return }
    let ux = (to.x - from.x) / length, uy = (to.y - from.y) / length
    let headLength = min(4.5 * lineWidth, 0.6 * length)
    let halfWidth = headLength * 0.6
    let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
    ctx.move(to: from)
    // The shaft stops inside the head so its round cap never pokes past the tip.
    ctx.addLine(to: CGPoint(x: base.x + ux * headLength / 2, y: base.y + uy * headLength / 2))
    ctx.strokePath()
    ctx.move(to: to)
    ctx.addLine(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
    ctx.addLine(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
    ctx.closePath()
    ctx.drawPath(using: .fillStroke)
}

/// Replaces `rect` with blocks of its average colour; at this size text in it can't be recovered.
private func pixelate(_ rect: CGRect, of base: CGImage, in ctx: CGContext, scale: CGFloat) {
    let region = rect.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
    guard !region.isEmpty, let crop = base.cropping(to: region) else { return }
    let block = (12 * scale).rounded()
    let cols = Int((region.width / block).rounded(.up)), rows = Int((region.height / block).rounded(.up))
    guard let small = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    small.interpolationQuality = .high
    small.draw(crop, in: CGRect(x: 0, y: 0, width: cols, height: rows))
    guard let blocks = small.makeImage() else { return }
    ctx.saveGState()
    ctx.clip(to: region)
    // Whole blocks anchored at the region's top-left; the clip trims the last row and column.
    let grid = CGRect(x: region.minX, y: region.minY, width: CGFloat(cols) * block, height: CGFloat(rows) * block)
    ctx.translateBy(x: 0, y: grid.minY + grid.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .none
    ctx.draw(blocks, in: grid)
    ctx.restoreGState()
}
