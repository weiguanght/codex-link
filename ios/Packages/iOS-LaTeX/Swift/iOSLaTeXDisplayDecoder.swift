import Foundation

private struct NativeDisplayReader {
    let bytes: UnsafeRawBufferPointer
    private(set) var offset = 0
    var remaining: Int { bytes.count - offset }

    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let width = MemoryLayout<T>.size
        guard remaining >= width else { throw iOSLaTeXError.invalidDisplayList }
        let value = bytes.loadUnaligned(fromByteOffset: offset, as: type)
        offset += width
        return T(littleEndian: value)
    }

    mutating func byte() throws -> UInt8 { try integer(UInt8.self) }
    mutating func double() throws -> Double { Double(bitPattern: try integer(UInt64.self)) }
    mutating func float() throws -> Float { Float(bitPattern: try integer(UInt32.self)) }

    mutating func color() throws -> iOSLaTeXColor {
        try iOSLaTeXColor(r: float(), g: float(), b: float(), a: float())
    }

    mutating func string() throws -> String {
        let length = Int(try byte())
        guard remaining >= length else { throw iOSLaTeXError.invalidDisplayList }
        let value = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
        offset += length
        return value
    }

    mutating func pathCommands() throws -> [PathCommand] {
        let count = Int(try integer(UInt32.self))
        guard count <= remaining else { throw iOSLaTeXError.invalidDisplayList }
        var result: [PathCommand] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            switch try byte() {
            case 0: try result.append(.moveTo(x: double(), y: double()))
            case 1: try result.append(.lineTo(x: double(), y: double()))
            case 2: try result.append(.cubicTo(x1: double(), y1: double(), x2: double(), y2: double(),
                                                x: double(), y: double()))
            case 3: try result.append(.quadTo(x1: double(), y1: double(), x: double(), y: double()))
            case 4: result.append(.close)
            default: throw iOSLaTeXError.invalidDisplayList
            }
        }
        return result
    }

    mutating func item() throws -> DisplayItem {
        let tag = try byte()
        let x = try double()
        let y = try double()
        switch tag {
        case 0:
            let scale = try double()
            let color = try color()
            let charCode = try integer(UInt32.self)
            let font = try string()
            return .glyphPath(GlyphPathData(x: x, y: y, scale: scale, font: font, charCode: charCode, color: color))
        case 1:
            return try .line(LineData(x: x, y: y, width: double(), thickness: double(),
                                      color: color(), dashed: byte() != 0))
        case 2:
            return try .rect(RectData(x: x, y: y, width: double(), height: double(), color: color()))
        case 3:
            let color = try color()
            let fill = try byte() != 0
            return try .path(PathData(x: x, y: y, commands: pathCommands(), fill: fill, color: color))
        default:
            throw iOSLaTeXError.invalidDisplayList
        }
    }
}

extension DisplayList {
    static func decodeNative(_ bytes: UnsafeRawBufferPointer) throws -> Self {
        var reader = NativeDisplayReader(bytes: bytes)
        guard try reader.integer(UInt32.self) == 0x01544D4E else { throw iOSLaTeXError.invalidDisplayList }
        let width = try reader.double()
        let height = try reader.double()
        let depth = try reader.double()
        let count = Int(try reader.integer(UInt32.self))
        // The smallest legal item header is a Path header at 38 bytes.
        guard count <= reader.remaining / 38 else { throw iOSLaTeXError.invalidDisplayList }
        var items: [DisplayItem] = []
        items.reserveCapacity(count)
        for _ in 0..<count { items.append(try reader.item()) }
        guard reader.remaining == 0 else { throw iOSLaTeXError.invalidDisplayList }
        return DisplayList(version: 1, width: width, height: height, depth: depth, items: items)
    }
}
