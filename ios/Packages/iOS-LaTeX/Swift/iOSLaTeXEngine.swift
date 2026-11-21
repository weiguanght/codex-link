// Native math layout and a bounded display-list cache.

import Foundation
import iOSLaTeXFFI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)

private func ffiColor(from color: NSColor, appearance: NSAppearance? = nil) -> IOSLaTeXColor {
    func resolve(_ c: NSColor) -> IOSLaTeXColor {
        guard let rgb = c.usingColorSpace(.sRGB) else {
            return IOSLaTeXColor(r: 0, g: 0, b: 0, a: 1)
        }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return IOSLaTeXColor(r: Float(r), g: Float(g), b: Float(b), a: Float(a))
    }

    if let appearance {
        var result = IOSLaTeXColor(r: 0, g: 0, b: 0, a: 1)
        appearance.performAsCurrentDrawingAppearance {
            result = resolve(color)
        }
        return result
    }

    return resolve(color)
}

#else

private func ffiColor(from color: UIColor, traitCollection: UITraitCollection? = nil) -> IOSLaTeXColor {
    let resolved = traitCollection.map { color.resolvedColor(with: $0) } ?? color
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
        return IOSLaTeXColor(r: Float(r), g: Float(g), b: Float(b), a: Float(a))
    }

    let fallbackSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
        let converted = resolved.cgColor.converted(
            to: fallbackSpace,
            intent: .defaultIntent,
            options: nil
        ),
        let components = converted.components,
        components.count >= 4
    else {
        return IOSLaTeXColor(r: 0, g: 0, b: 0, a: 1)
    }

    return IOSLaTeXColor(
        r: Float(components[0]),
        g: Float(components[1]),
        b: Float(components[2]),
        a: Float(components[3])
    )
}

#endif

public enum iOSLaTeXError: LocalizedError {
    case formula(String)
    case invalidDisplayList

    public var errorDescription: String? {
        switch self {
        case .formula(let message): return message
        case .invalidDisplayList: return "Invalid native display list"
        }
    }
}

private final class LayoutKey: NSObject {
    let latex: String
    let style: Int32
    let color: IOSLaTeXColor

    init(_ latex: String, _ style: Int32, _ color: IOSLaTeXColor) {
        self.latex = latex
        self.style = style
        self.color = color
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(latex)
        hasher.combine(style)
        hasher.combine(color.r)
        hasher.combine(color.g)
        hasher.combine(color.b)
        hasher.combine(color.a)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? LayoutKey else { return false }
        return style == other.style && latex == other.latex
            && color.r == other.color.r && color.g == other.color.g
            && color.b == other.color.b && color.a == other.color.a
    }
}

private final class CachedLayout {
    let displayList: DisplayList
    init(_ displayList: DisplayList) { self.displayList = displayList }
}

/// Synchronous native layout. On a long or complex formula, call off the UI thread.
public final class iOSLaTeXEngine: @unchecked Sendable {
    public static let shared = iOSLaTeXEngine()
    public static var supportsChemistry: Bool { ios_latex_has_chemistry() == 1 }

    private let cache = NSCache<LayoutKey, CachedLayout>()

    /// A zero count or byte limit disables caching.
    public init(cacheEntries: Int = 192, estimatedCacheBytes: Int = 2 * 1024 * 1024) {
        cache.countLimit = max(cacheEntries, 0)
        cache.totalCostLimit = max(estimatedCacheBytes, 0)
    }

    public func resetCache() { cache.removeAllObjects() }

    #if os(macOS)
    public func parse(
        _ latex: String,
        displayMode: Bool? = nil,
        color: NSColor = .black,
        useCache: Bool = true
    ) throws -> DisplayList {
        try parse(latex, displayMode: displayMode, color: color, appearance: nil, useCache: useCache)
    }

    func parse(
        _ latex: String,
        displayMode: Bool?,
        color: NSColor,
        appearance: NSAppearance?,
        useCache: Bool = true
    ) throws -> DisplayList {
        try layout(latex, displayMode, ffiColor(from: color, appearance: appearance), useCache)
    }
    #else
    public func parse(
        _ latex: String,
        displayMode: Bool? = nil,
        color: UIColor = .black,
        useCache: Bool = true
    ) throws -> DisplayList {
        try parse(latex, displayMode: displayMode, color: color, traitCollection: nil, useCache: useCache)
    }

    func parse(
        _ latex: String,
        displayMode: Bool?,
        color: UIColor,
        traitCollection: UITraitCollection?,
        useCache: Bool = true
    ) throws -> DisplayList {
        try layout(latex, displayMode, ffiColor(from: color, traitCollection: traitCollection), useCache)
    }
    #endif

    private func layout(
        _ input: String, _ displayMode: Bool?, _ inputColor: IOSLaTeXColor, _ useCache: Bool
    ) throws -> DisplayList {
        let style: Int32 = displayMode.map { $0 ? 1 : 0 } ?? -1
        func unit(_ value: Float) -> Float {
            value.isFinite ? min(1, max(0, value)) : 0
        }
        let color = IOSLaTeXColor(r: unit(inputColor.r), g: unit(inputColor.g),
                               b: unit(inputColor.b), a: unit(inputColor.a))
        let canCache = useCache && cache.countLimit > 0 && cache.totalCostLimit > 0
        let key = canCache ? LayoutKey(input, style, color) : nil
        if let key, let hit = cache.object(forKey: key) { return hit.displayList }

        var latex = input
        latex.makeContiguousUTF8()
        func calculate(_ bytes: UnsafeBufferPointer<UInt8>) throws -> (DisplayList, Int) {
            let frame = ios_latex_layout(bytes.baseAddress, bytes.count, style, color)
            guard let data = frame.data else {
                let error = ios_latex_last_error().map { String(cString: $0) } ?? "Formula layout failed"
                throw iOSLaTeXError.formula(error)
            }
            defer { ios_latex_free(frame) }
            let list = try DisplayList.decodeNative(UnsafeRawBufferPointer(start: data, count: frame.length))
            return (list, frame.length)
        }
        let result: (DisplayList, Int)
        if let contiguous = try latex.utf8.withContiguousStorageIfAvailable(calculate) {
            result = contiguous
        } else {
            result = try Array(latex.utf8).withUnsafeBufferPointer(calculate)
        }
        if let key {
            let cost = result.1 * 2 + input.utf8.count + 128
            if cost <= cache.totalCostLimit {
                cache.setObject(CachedLayout(result.0), forKey: key, cost: cost)
            }
        }
        return result.0
    }
}
