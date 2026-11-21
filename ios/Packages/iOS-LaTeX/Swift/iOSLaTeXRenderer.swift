// CoreGraphics + CoreText renderer for an iOSLaTeX DisplayList.
//
// Key insight: GlyphPath.commands are PLACEHOLDER RECTANGLES (bounding boxes),
// not real glyph outlines. Glyphs must be drawn with CTFont using font + char_code.
// Non-glyph items (Line, Rect, Path) use their commands directly.
//
// Fonts are registered automatically on first draw via iOSLaTeXFontLoader.ensureLoaded();
// or preload them at startup via iOSLaTeXFontLoader.

import CoreGraphics
import CoreText
import Foundation

// CTLine objects are immutable. Reusing them keeps font lookup and shaping
// out of repeat drawing while retaining CoreText fallback and script handling.
private final class GlyphLineKey: NSObject {
    let font: String
    let charCode: UInt32
    let size: CGFloat
    let color: iOSLaTeXColor

    init(_ glyph: GlyphPathData, size: CGFloat) {
        font = glyph.font
        charCode = glyph.charCode
        self.size = size
        color = glyph.color
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(font)
        hasher.combine(charCode)
        hasher.combine(size)
        hasher.combine(color.r)
        hasher.combine(color.g)
        hasher.combine(color.b)
        hasher.combine(color.a)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? GlyphLineKey else { return false }
        return font == other.font && charCode == other.charCode
            && size == other.size && color == other.color
    }
}

private final class CachedGlyphLine {
    let line: CTLine
    init(_ line: CTLine) { self.line = line }
}

public struct iOSLaTeXRenderer {
    private static let glyphLines: NSCache<GlyphLineKey, CachedGlyphLine> = {
        let cache = NSCache<GlyphLineKey, CachedGlyphLine>()
        cache.countLimit = 512
        return cache
    }()

    public let displayList: DisplayList
    /// Font size in points. All em-unit coordinates are multiplied by this value.
    public let fontSize: CGFloat

    public init(displayList: DisplayList, fontSize: CGFloat = 24) {
        self.displayList = displayList
        self.fontSize = fontSize.isFinite ? min(4_096, max(0, fontSize)) : 0
    }

    // MARK: - Dimensions (in points)

    public var width:       CGFloat { CGFloat(displayList.width)  * fontSize }
    public var height:      CGFloat { CGFloat(displayList.height) * fontSize }
    public var depth:       CGFloat { CGFloat(displayList.depth)  * fontSize }
    public var totalHeight: CGFloat { height + depth }

    // MARK: - Drawing

    /// Draw the formula into `context`.
    /// The origin is the top-left of the formula's bounding box.
    public func draw(in context: CGContext) {
        guard fontSize > 0 else { return }
        iOSLaTeXFontLoader.ensureLoaded()

        for item in displayList.items {
            switch item {
            case .glyphPath(let g): drawGlyph(g, in: context)
            case .line(let l):      drawLine(l, in: context)
            case .rect(let r):      drawRect(r, in: context)
            case .path(let p):      drawPath(p, in: context)
            case .unknown:
                // Forward compatibility: ignore items newer than this decoder.
                break
            }
        }
    }

    // MARK: - Private helpers

    /// Convert em units to points.
    private func pt(_ em: Double) -> CGFloat { CGFloat(em) * fontSize }

    private func cgColor(_ c: iOSLaTeXColor) -> CGColor {
        CGColor(red: CGFloat(c.r), green: CGFloat(c.g),
                blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    // MARK: Glyph (CoreText)

    /// Map iOSLaTeX font ID ("Math-Italic") to the KaTeX PostScript name ("KaTeX_Math-Italic").
    private func postScriptName(for fontId: String) -> String {
        "KaTeX_\(fontId)"
    }

    private func drawGlyph(_ g: GlyphPathData, in ctx: CGContext) {
        guard let scalar = Unicode.Scalar(g.charCode) else { return }
        let key = GlyphLineKey(g, size: pt(g.scale))
        let line: CTLine
        if let hit = Self.glyphLines.object(forKey: key) {
            line = hit.line
        } else {
            let font = CTFontCreateWithName(postScriptName(for: g.font) as CFString, key.size, nil)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: cgColor(g.color),
            ]
            guard let string = CFAttributedStringCreate(nil, String(scalar) as CFString, attrs as CFDictionary)
                else { return }
            line = CTLineCreateWithAttributedString(string)
            Self.glyphLines.setObject(CachedGlyphLine(line), forKey: key)
        }

        ctx.saveGState()

        // In UIKit's draw(_:) context, Y increases downward (UIKit has already flipped the CTM).
        // The GlyphPath y-coordinate is the alphabetic baseline measured downward from the top.
        ctx.translateBy(x: pt(g.x), y: pt(g.y))

        // CoreText draws upward from the baseline.
        // UIKit's flipped CTM would make CoreText text appear upside-down.
        // textMatrix = (1,0,0,-1) counteracts the y-flip for text rendering.
        ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)

        CTLineDraw(line, ctx)

        ctx.restoreGState()
    }

    // MARK: Line

    private func drawLine(_ l: LineData, in ctx: CGContext) {
        ctx.saveGState()
        let t = max(0.5, pt(l.thickness))
        let halfT = t / 2
        if l.dashed {
            ctx.setStrokeColor(cgColor(l.color))
            ctx.setLineWidth(t)
            ctx.setLineCap(.butt)
            let dashLen = t * 3
            ctx.setLineDash(phase: 0, lengths: [dashLen, dashLen])
            ctx.move(to: CGPoint(x: pt(l.x), y: pt(l.y)))
            ctx.addLine(to: CGPoint(x: pt(l.x) + pt(l.width), y: pt(l.y)))
            ctx.strokePath()
        } else {
            ctx.setFillColor(cgColor(l.color))
            ctx.fill(CGRect(x: pt(l.x), y: pt(l.y) - halfT,
                            width: pt(l.width), height: t))
        }
        ctx.restoreGState()
    }

    // MARK: Rect

    private func drawRect(_ r: RectData, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(cgColor(r.color))
        ctx.fill(CGRect(x: pt(r.x), y: pt(r.y),
                        width: pt(r.width), height: pt(r.height)))
        ctx.restoreGState()
    }

    // MARK: Path (radical signs, delimiters, etc.)

    private func makeCGPath(from commands: [PathCommand], dx: Double = 0, dy: Double = 0) -> CGPath {
        let path = CGMutablePath()
        let ox = pt(dx), oy = pt(dy)
        for cmd in commands {
            switch cmd {
            case .moveTo(let x, let y):
                path.move(to: CGPoint(x: ox + pt(x), y: oy + pt(y)))
            case .lineTo(let x, let y):
                path.addLine(to: CGPoint(x: ox + pt(x), y: oy + pt(y)))
            case .cubicTo(let x1, let y1, let x2, let y2, let x, let y):
                path.addCurve(to:       CGPoint(x: ox + pt(x),  y: oy + pt(y)),
                              control1: CGPoint(x: ox + pt(x1), y: oy + pt(y1)),
                              control2: CGPoint(x: ox + pt(x2), y: oy + pt(y2)))
            case .quadTo(let x1, let y1, let x, let y):
                path.addQuadCurve(to:      CGPoint(x: ox + pt(x),  y: oy + pt(y)),
                                  control: CGPoint(x: ox + pt(x1), y: oy + pt(y1)))
            case .close:
                path.closeSubpath()
            case .unknown:
                // Forward compatibility: ignore newer command variants.
                break
            }
        }
        return path
    }

    private func drawPath(_ p: PathData, in ctx: CGContext) {
        ctx.saveGState()
        let cgPath = makeCGPath(from: p.commands, dx: p.x, dy: p.y)
        ctx.addPath(cgPath)
        let color = cgColor(p.color)
        if p.fill {
            ctx.setFillColor(color)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(color)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
