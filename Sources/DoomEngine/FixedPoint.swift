#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// 16.16 fixed-point number, equivalent to the original engine's `fixed_t`.
public struct Fixed: Hashable, Comparable, Sendable {
    public var raw: Int32

    public init(raw: Int32) { self.raw = raw }
    public init(_ int: Int) { self.raw = Fixed.sat(Int64(int) << 16) }
    public init(_ int: Int32) { self.raw = Fixed.sat(Int64(int) << 16) }
    public init(_ double: Double) { self.raw = Fixed.sat(Int64((double * 65536.0).rounded())) }

    @inline(__always)
    static func sat(_ v: Int64) -> Int32 {
        if v > Int64(Int32.max) { return Int32.max }
        if v < Int64(Int32.min) { return Int32.min }
        return Int32(v)
    }

    public static let zero = Fixed(raw: 0)
    public static let one = Fixed(raw: 1 << 16)

    public var double: Double { Double(raw) / 65536.0 }
    public var int: Int32 { raw >> 16 }

    public static func + (a: Fixed, b: Fixed) -> Fixed { Fixed(raw: a.raw &+ b.raw) }
    public static func - (a: Fixed, b: Fixed) -> Fixed { Fixed(raw: a.raw &- b.raw) }
    public static prefix func - (a: Fixed) -> Fixed { Fixed(raw: -a.raw) }
    /// Fixed multiply with saturation (same overflow behavior as the
    /// original engine's 64-bit intermediate, but never traps).
    public static func * (a: Fixed, b: Fixed) -> Fixed {
        Fixed(raw: sat((Int64(a.raw) * Int64(b.raw)) >> 16))
    }
    public static func / (a: Fixed, b: Fixed) -> Fixed {
        precondition(b.raw != 0, "Fixed division by zero")
        return Fixed(raw: sat((Int64(a.raw) << 16) / Int64(b.raw)))
    }
    public static func * (a: Fixed, b: Int32) -> Fixed { Fixed(raw: sat(Int64(a.raw) * Int64(b))) }
    public static func < (a: Fixed, b: Fixed) -> Bool { a.raw < b.raw }
    public static func += (a: inout Fixed, b: Fixed) { a = a + b }
    public static func -= (a: inout Fixed, b: Fixed) { a = a - b }
    public var abs: Fixed { Fixed(raw: raw < 0 ? -raw : raw) }
}

/// Binary angle measurement: the full circle is 2^32, matching `angle_t`.
public typealias Angle = UInt32

public enum Angles {
    public static let deg45: Angle = 0x2000_0000
    public static let deg90: Angle = 0x4000_0000
    public static let deg180: Angle = 0x8000_0000
    public static let deg270: Angle = 0xC000_0000
    public static let deg360: Angle = 0 // wraps

    public static func degrees(_ d: Double) -> Angle {
        var dd = d.truncatingRemainder(dividingBy: 360)
        if dd < 0 { dd += 360 }
        return Angle(UInt64((dd / 360.0) * 4294967296.0) & 0xFFFF_FFFF)
    }
    public static func toDegrees(_ a: Angle) -> Double {
        Double(a) / 4294967296.0 * 360.0
    }
    /// Signed shortest difference a - b.
    public static func diff(_ a: Angle, _ b: Angle) -> Int32 {
        Int32(bitPattern: a &- b)
    }
}

/// Sine/cosine lookup over a full circle using BAM angles.
public enum Trig {
    public static let tableBits = 13 // 8192 entries
    public static let tableSize = 1 << tableBits
    static let sineTable: [Fixed] = {
        var t: [Fixed] = []
        t.reserveCapacity(tableSize)
        for i in 0..<tableSize {
            let radians = Double(i) * (2.0 * .pi / Double(tableSize))
            #if canImport(Glibc)
            t.append(Fixed(Glibc.sin(radians)))
            #else
            t.append(Fixed(Darwin.sin(radians)))
            #endif
        }
        return t
    }()

    @inline(__always)
    static func index(_ a: Angle) -> Int { Int(a >> (32 - tableBits)) & (tableSize - 1) }

    public static func sin(_ a: Angle) -> Fixed { sineTable[index(a)] }
    public static func cos(_ a: Angle) -> Fixed {
        sineTable[index(a &+ Angle(tableSize / 4) << (32 - tableBits))]
    }
    public static func tan(_ a: Angle) -> Fixed {
        let c = cos(a)
        if c.raw == 0 { return Fixed(raw: Int32.max) }
        return sin(a) / c
    }
    /// sin/cos as Double for projection math.
    public static func sinD(_ a: Angle) -> Double { sin(a).double }
    public static func cosD(_ a: Angle) -> Double { cos(a).double }
}

/// 2D point in fixed-point map units.
public struct Vec2: Hashable, Sendable {
    public var x: Fixed
    public var y: Fixed
    public init(x: Fixed, y: Fixed) { self.x = x; self.y = y }
    public static let zero = Vec2(x: .zero, y: .zero)
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(x: a.x - b.x, y: a.y - b.y) }
    public func dot(_ o: Vec2) -> Fixed { x * o.x + y * o.y }
    /// Z of the 2D cross product self × o.
    public func cross(_ o: Vec2) -> Fixed { x * o.y - y * o.x }
    public var length: Double { (x.double * x.double + y.double * y.double).squareRoot() }
    public var angle: Angle {
        let d = atan2(y.double, x.double)
        return Angles.degrees(d * 180.0 / Double.pi)
    }
}

/// Which side of a directed line (from `a` toward `b`) point `p` lies on.
/// Returns +1, -1, or 0 when exactly on the line.
@inline(__always)
public func lineSide(_ a: Vec2, _ b: Vec2, _ p: Vec2) -> Int {
    // Compute the cross product in 64-bit to avoid 16.16 overflow — raw
    // deltas are clamped so each product stays well inside Int64.
    func cl(_ v: Int64) -> Int64 { max(-(1 << 26), min(1 << 26, v)) }
    let dx = cl(Int64(b.x.raw) - Int64(a.x.raw))
    let dy = cl(Int64(b.y.raw) - Int64(a.y.raw))
    let px = cl(Int64(p.x.raw) - Int64(a.x.raw))
    let py = cl(Int64(p.y.raw) - Int64(a.y.raw))
    let d = dx * py - dy * px
    if d > 0 { return 1 }
    if d < 0 { return -1 }
    return 0
}
