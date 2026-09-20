import Foundation

/// A single named lump in a WAD archive.
public struct Lump: Sendable {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

/// Directory entry pointing into WAD data.
struct LumpEntry {
    let offset: UInt32
    let size: UInt32
    let name: String
}

/// Parsed DOOM WAD archive (IWAD or PWAD). Parsing is format-level only —
/// no interpretation of game assets happens here.
public final class WadFile {
    public enum Kind: String, Sendable {
        case iwad = "IWAD"
        case pwad = "PWAD"
    }

    public let kind: Kind
    public private(set) var lumps: [Lump] = []
    private var nameToIndices: [String: [Int]] = [:]

    public enum WadError: Error, CustomStringConvertible {
        case truncated
        case badMagic
        case badDirectory
        public var description: String {
            switch self {
            case .truncated: return "WAD data is truncated"
            case .badMagic: return "not a WAD file (bad magic)"
            case .badDirectory: return "WAD directory out of bounds"
            }
        }
    }

    public init(data: Data) throws {
        guard data.count >= 12 else { throw WadError.truncated }
        let magic = String(decoding: data[0..<4], as: UTF8.self)
        guard let kind = Kind(rawValue: magic) else { throw WadError.badMagic }
        self.kind = kind

        let numLumps = Int(readU32(data, 4))
        let dirOfs = Int(readU32(data, 8))
        guard dirOfs >= 0, dirOfs + numLumps * 16 <= data.count else {
            throw WadError.badDirectory
        }

        for i in 0..<numLumps {
            let base = dirOfs + i * 16
            let ofs = readU32(data, base)
            let size = readU32(data, base + 4)
            let name = readLumpName(data, base + 8)
            guard Int(ofs) + Int(size) <= data.count else { throw WadError.badDirectory }
            let lumpData = data[Int(ofs)..<Int(ofs + size)]
            let idx = lumps.count
            lumps.append(Lump(name: name, data: Data(lumpData)))
            nameToIndices[name, default: []].append(idx)
        }
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// Lump names are uppercased and truncated to 8 characters (WAD limit).
    static func normName(_ s: String) -> String { String(s.uppercased().prefix(8)) }

    /// Last lump with the given name (PWADs override by appending).
    public func lump(named name: String) -> Lump? {
        guard let idx = nameToIndices[WadFile.normName(name)]?.last else { return nil }
        return lumps[idx]
    }

    public func lumpIndex(named name: String) -> Int? {
        nameToIndices[WadFile.normName(name)]?.last
    }

    public func allLumps(named name: String) -> [Lump] {
        (nameToIndices[WadFile.normName(name)] ?? []).map { lumps[$0] }
    }

    /// Indices of lumps that make up a map, starting at the map marker.
    /// Returns (markerIndex, dataLumps) where dataLumps are keyed by lump name.
    public func mapLumps(named mapName: String) -> (marker: Int, lumps: [String: Lump])? {
        let key = WadFile.normName(mapName)
        guard let start = nameToIndices[key]?.last else { return nil }
        var result: [String: Lump] = [:]
        let mapLumpNames: Set<String> = [
            "THINGS", "LINEDEFS", "SIDEDEFS", "VERTEXES", "SEGS",
            "SSECTORS", "NODES", "SECTORS", "REJECT", "BLOCKMAP",
            "BEHAVIOR", "SCRIPTS",
        ]
        for i in (start + 1)..<lumps.count {
            let l = lumps[i]
            if !mapLumpNames.contains(l.name) { break }
            result[l.name] = l
        }
        return (start, result)
    }

    /// Lump index range between two namespace markers (e.g. S_START/S_END),
    /// for sprite/flat namespaces. Returns interior indices only.
    public func namespaceRange(start markerA: String, end markerB: String) -> Range<Int>? {
        guard let a = nameToIndices[WadFile.normName(markerA)]?.last,
              let b = nameToIndices[WadFile.normName(markerB)]?.last, b > a else { return nil }
        return (a + 1)..<b
    }
}

@inline(__always)
func readU16(_ d: Data, _ o: Int) -> UInt16 {
    UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
}
@inline(__always)
func readI16(_ d: Data, _ o: Int) -> Int16 {
    Int16(bitPattern: readU16(d, o))
}
@inline(__always)
func readU32(_ d: Data, _ o: Int) -> UInt32 {
    UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
}
@inline(__always)
func readI32(_ d: Data, _ o: Int) -> Int32 {
    Int32(bitPattern: readU32(d, o))
}
@inline(__always)
func readLumpName(_ d: Data, _ o: Int) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(8)
    for i in 0..<8 {
        let c = d[o + i]
        if c == 0 { break }
        bytes.append(c)
    }
    return String(decoding: bytes, as: UTF8.self).uppercased()
}

/// Builds a valid WAD in memory. Used by the test-fixture generator and the
/// `mktwad` CLI command — the engine ships no copyrighted data.
public struct WadBuilder {
    public private(set) var lumps: [Lump] = []
    public init() {}
    public mutating func addLump(_ name: String, data: Data) {
        lumps.append(Lump(name: WadBuilder.lumpName(name), data: data))
    }
    public mutating func addMarker(_ name: String) { addLump(name, data: Data()) }

    static func lumpName(_ s: String) -> String {
        String(s.uppercased().prefix(8))
    }

    public func build(kind: WadFile.Kind = .pwad) -> Data {
        var out = Data()
        var header = Data(kind.rawValue.utf8)
        header.append(contentsOf: [0, 0, 0, 0]) // numlumps
        header.append(contentsOf: [0, 0, 0, 0]) // dirofs
        out.append(header)

        var entries: [(UInt32, UInt32, String)] = []
        for l in lumps {
            entries.append((UInt32(out.count), UInt32(l.data.count), l.name))
            out.append(l.data)
        }
        let dirOfs = UInt32(out.count)
        for e in entries {
            var le = Data()
            le.append(uint32(e.0))
            le.append(uint32(e.1))
            var nb = Data(Array(e.2.utf8.prefix(8)))
            while nb.count < 8 { nb.append(0) }
            le.append(nb)
            out.append(le)
        }
        // patch header
        out.replaceSubrange(4..<8, with: uint32(UInt32(lumps.count)))
        out.replaceSubrange(8..<12, with: uint32(dirOfs))
        return out
    }
}

func uint16(_ v: UInt16) -> Data {
    Data([UInt8(v & 0xFF), UInt8(v >> 8)])
}
func uint32(_ v: UInt32) -> Data {
    Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
}
func int16(_ v: Int16) -> Data { uint16(UInt16(bitPattern: v)) }
