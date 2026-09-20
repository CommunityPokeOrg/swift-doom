import Foundation

// MARK: - Map structures

public struct MapVertex: Sendable {
    public var x: Fixed
    public var y: Fixed
    public var vec: Vec2 { Vec2(x: x, y: y) }
}

public enum LineFlags {
    public static let blocking: UInt16 = 1
    public static let blockMonsters: UInt16 = 2
    public static let twoSided: UInt16 = 4
    public static let upperUnpegged: UInt16 = 8
    public static let lowerUnpegged: UInt16 = 16
    public static let secret: UInt16 = 32
    public static let blockSound: UInt16 = 64
    public static let neverOnMap: UInt16 = 128
    public static let alreadyOnMap: UInt16 = 256
}

public struct Linedef: Sendable {
    public var v1: Int
    public var v2: Int
    public var flags: UInt16
    public var special: UInt16
    public var tag: UInt16
    /// -1 when no sidedef on that side.
    public var sidedef: [Int]
    public var bboxMin: Vec2 = .zero
    public var bboxMax: Vec2 = .zero
}

public struct Sidedef: Sendable {
    public var textureOffset: Fixed
    public var rowOffset: Fixed
    public var upperTexture: String
    public var lowerTexture: String
    public var middleTexture: String
    public var sector: Int
}

public struct Sector: Sendable {
    public var floorHeight: Fixed
    public var ceilingHeight: Fixed
    public var floorFlat: String
    public var ceilingFlat: String
    public var light: Int
    public var special: Int
    public var tag: Int
}

public struct MapThing: Sendable {
    public var x: Fixed
    public var y: Fixed
    public var angle: Angle
    public var type: Int
    public var flags: Int
}

public struct Seg: Sendable {
    public var v1: Int
    public var v2: Int
    public var angle: Angle
    public var linedef: Int
    /// 0 = seg faces the front sidedef, 1 = back sidedef.
    public var side: Int
    public var offset: Fixed
}

public struct SubSector: Sendable {
    public var segCount: Int
    public var firstSeg: Int
}

public struct MapNode: Sendable {
    public var x: Fixed
    public var y: Fixed
    public var dx: Fixed
    public var dy: Fixed
    /// [child][minY,maxY,minX,maxX] in order top,bottom,left,right.
    public var bbox: [[Int16]]
    public var children: [UInt16]

    public static let subsectorBit: UInt16 = 0x8000
    public func childIsSubsector(_ i: Int) -> Bool { children[i] & MapNode.subsectorBit != 0 }
    public func childIndex(_ i: Int) -> Int { Int(children[i] & ~MapNode.subsectorBit) }
}

/// A fully parsed map (the classic 10-lump format).
public final class MapData {
    public let name: String
    public private(set) var things: [MapThing] = []
    public private(set) var linedefs: [Linedef] = []
    public private(set) var sidedefs: [Sidedef] = []
    public private(set) var vertexes: [MapVertex] = []
    public private(set) var segs: [Seg] = []
    public private(set) var subsectors: [SubSector] = []
    public private(set) var nodes: [MapNode] = []
    public private(set) var sectors: [Sector] = []
    /// BLOCKMAP: [cellX, cellY] -> linedef indices.
    public private(set) var blockmap: [Int: [Int]] = [:]
    public private(set) var blockOrigin = Vec2.zero
    public private(set) var blockCols = 0
    public private(set) var blockRows = 0

    public enum MapError: Error, CustomStringConvertible {
        case notFound(String)
        case missingLump(String)
        case malformed(String)
        public var description: String {
            switch self {
            case .notFound(let m): return "map \(m) not found in WAD"
            case .missingLump(let l): return "map missing required lump \(l)"
            case .malformed(let l): return "map lump \(l) is malformed"
            }
        }
    }

    public init(wad: WadFile, name: String) throws {
        self.name = name
        guard let (_, lumps) = wad.mapLumps(named: name) else {
            throw MapError.notFound(name)
        }
        func required(_ n: String) throws -> Lump {
            guard let l = lumps[n] else { throw MapError.missingLump(n) }
            return l
        }
        try loadVertexes(try required("VERTEXES").data)
        try loadSectors(try required("SECTORS").data)
        try loadSidedefs(try required("SIDEDEFS").data)
        try loadLinedefs(try required("LINEDEFS").data)
        try loadThings(try required("THINGS").data)
        try loadSegs(try required("SEGS").data)
        try loadSubsectors(try required("SSECTORS").data)
        try loadNodes(try required("NODES").data)
        if let b = lumps["BLOCKMAP"] { loadBlockmap(b.data) }
    }

    private func loadVertexes(_ d: Data) throws {
        guard d.count % 4 == 0 else { throw MapError.malformed("VERTEXES") }
        for i in stride(from: 0, to: d.count, by: 4) {
            vertexes.append(MapVertex(x: Fixed(Int32(readI16(d, i))),
                                      y: Fixed(Int32(readI16(d, i + 2)))))
        }
    }

    private func loadLinedefs(_ d: Data) throws {
        guard d.count % 14 == 0 else { throw MapError.malformed("LINEDEFS") }
        for i in stride(from: 0, to: d.count, by: 14) {
            var ld = Linedef(
                v1: Int(readU16(d, i)), v2: Int(readU16(d, i + 2)),
                flags: readU16(d, i + 4), special: readU16(d, i + 6),
                tag: readU16(d, i + 8),
                sidedef: [Int(readI16(d, i + 10)), Int(readI16(d, i + 12))]
            )
            let a = vertexes[ld.v1].vec, b = vertexes[ld.v2].vec
            ld.bboxMin = Vec2(x: min(a.x, b.x), y: min(a.y, b.y))
            ld.bboxMax = Vec2(x: max(a.x, b.x), y: max(a.y, b.y))
            linedefs.append(ld)
        }
    }

    private func loadSidedefs(_ d: Data) throws {
        guard d.count % 30 == 0 else { throw MapError.malformed("SIDEDEFS") }
        for i in stride(from: 0, to: d.count, by: 30) {
            sidedefs.append(Sidedef(
                textureOffset: Fixed(Int32(readI16(d, i))),
                rowOffset: Fixed(Int32(readI16(d, i + 2))),
                upperTexture: readLumpName(d, i + 4),
                lowerTexture: readLumpName(d, i + 12),
                middleTexture: readLumpName(d, i + 20),
                sector: Int(readU16(d, i + 28))
            ))
        }
    }

    private func loadSectors(_ d: Data) throws {
        guard d.count % 26 == 0 else { throw MapError.malformed("SECTORS") }
        for i in stride(from: 0, to: d.count, by: 26) {
            sectors.append(Sector(
                floorHeight: Fixed(Int32(readI16(d, i))),
                ceilingHeight: Fixed(Int32(readI16(d, i + 2))),
                floorFlat: readLumpName(d, i + 4),
                ceilingFlat: readLumpName(d, i + 12),
                light: Int(readI16(d, i + 20)),
                special: Int(readI16(d, i + 22)),
                tag: Int(readI16(d, i + 24))
            ))
        }
    }

    private func loadThings(_ d: Data) throws {
        guard d.count % 10 == 0 else { throw MapError.malformed("THINGS") }
        for i in stride(from: 0, to: d.count, by: 10) {
            things.append(MapThing(
                x: Fixed(Int32(readI16(d, i))),
                y: Fixed(Int32(readI16(d, i + 2))),
                angle: Angles.degrees(Double(readU16(d, i + 4))),
                type: Int(readU16(d, i + 6)),
                flags: Int(readU16(d, i + 8))
            ))
        }
    }

    private func loadSegs(_ d: Data) throws {
        guard d.count % 12 == 0 else { throw MapError.malformed("SEGS") }
        for i in stride(from: 0, to: d.count, by: 12) {
            segs.append(Seg(
                v1: Int(readU16(d, i)), v2: Int(readU16(d, i + 2)),
                angle: Angle(readU16(d, i + 4)) << 16,
                linedef: Int(readU16(d, i + 6)),
                side: Int(readI16(d, i + 8)),
                offset: Fixed(Int32(readI16(d, i + 10)))
            ))
        }
    }

    private func loadSubsectors(_ d: Data) throws {
        guard d.count % 4 == 0 else { throw MapError.malformed("SSECTORS") }
        for i in stride(from: 0, to: d.count, by: 4) {
            subsectors.append(SubSector(segCount: Int(readU16(d, i)),
                                        firstSeg: Int(readU16(d, i + 2))))
        }
    }

    private func loadNodes(_ d: Data) throws {
        guard d.count % 28 == 0 else { throw MapError.malformed("NODES") }
        for i in stride(from: 0, to: d.count, by: 28) {
            var bbox: [[Int16]] = [[], []]
            for c in 0..<2 {
                let b = i + 4 + c * 8
                bbox[c] = [readI16(d, b), readI16(d, b + 2), readI16(d, b + 4), readI16(d, b + 6)]
            }
            nodes.append(MapNode(
                x: Fixed(Int32(readI16(d, i))), y: Fixed(Int32(readI16(d, i + 2))),
                dx: Fixed(Int32(readI16(d, i + 4))), dy: Fixed(Int32(readI16(d, i + 6))),
                bbox: bbox,
                children: [readU16(d, i + 24), readU16(d, i + 26)]
            ))
        }
    }

    private func loadBlockmap(_ d: Data) {
        guard d.count >= 8 else { return }
        let originX = Int(readI16(d, 0))
        let originY = Int(readI16(d, 2))
        blockCols = Int(readU16(d, 4))
        blockRows = Int(readU16(d, 6))
        blockOrigin = Vec2(x: Fixed(Int32(originX)), y: Fixed(Int32(originY)))
        let cellCount = blockCols * blockRows
        guard 8 + cellCount * 2 <= d.count else { return }
        for c in 0..<cellCount {
            let listOfs = Int(readU16(d, 8 + c * 2))
            var lines: [Int] = []
            var o = listOfs
            while o + 1 < d.count {
                let v = Int(readI16(d, o))
                o += 2
                if v == -1 { break }
                if v != 0 { lines.append(v) }
            }
            blockmap[c] = lines
        }
    }

    /// Linedef indices in the blockmap cell containing point `p`.
    public func blockLines(at p: Vec2) -> [Int] {
        let cx = Int((p.x - blockOrigin.x).raw >> 16) / 128
        let cy = Int((p.y - blockOrigin.y).raw >> 16) / 128
        guard cx >= 0, cy >= 0, cx < blockCols, cy < blockRows else { return [] }
        return blockmap[cy * blockCols + cx] ?? []
    }

    /// All linedef indices in cells overlapped by the given AABB.
    public func blockLines(minx: Fixed, miny: Fixed, maxx: Fixed, maxy: Fixed) -> [Int] {
        if blockCols == 0 { return Array(0..<linedefs.count) }
        let cx0 = max(0, Int(minx.int - blockOrigin.x.int) / 128)
        let cx1 = min(blockCols - 1, Int(maxx.int - blockOrigin.x.int) / 128)
        let cy0 = max(0, Int(miny.int - blockOrigin.y.int) / 128)
        let cy1 = min(blockRows - 1, Int(maxy.int - blockOrigin.y.int) / 128)
        if cx0 > cx1 || cy0 > cy1 { return [] }
        var out: [Int] = []
        var seen = Set<Int>()
        for cy in cy0...cy1 {
            for cx in cx0...cx1 {
                for li in blockmap[cy * blockCols + cx] ?? [] where seen.insert(li).inserted {
                    out.append(li)
                }
            }
        }
        return out
    }

    /// Exact point-in-sector test: cast a +x ray and count boundary-edge
    /// crossings over every linedef that borders `sector` (handles portals,
    /// islands, and donut-shaped sectors correctly).
    public func pointInSector(_ p: Vec2, sector: Int) -> Bool {
        var inside = false
        let px = p.x.double, py = p.y.double
        for ld in linedefs {
            var touches = false
            for sd in ld.sidedef where sd >= 0 {
                if sidedefs[sd].sector == sector { touches = true }
            }
            if !touches { continue }
            let a = vertexes[ld.v1].vec, b = vertexes[ld.v2].vec
            let ay = a.y.double, by = b.y.double
            if (ay > py) == (by > py) { continue }
            let xint = a.x.double + (py - ay) / (by - ay) * (b.x.double - a.x.double)
            if px < xint { inside.toggle() }
        }
        return inside
    }

    /// Sector of the subsector containing `p`, via BSP walk. Falls back to 0.
    public func sectorAt(_ p: Vec2) -> Int {
        if nodes.isEmpty { return 0 }
        var nodeIdx = 0
        while true {
            let node = nodes[nodeIdx]
            let side = lineSide(Vec2(x: node.x, y: node.y),
                              Vec2(x: node.x + node.dx, y: node.y + node.dy), p)
            // Doom node child 0 is the "front" = right side of the partition
            // direction, i.e. where the 2D cross product is <= 0.
            let child = side <= 0 ? 0 : 1
            if node.childIsSubsector(child) {
                let ss = subsectors[node.childIndex(child)]
                // Candidate sectors from the leaf's segs, smallest seg-bbox
                // first (innermost region, e.g. a raised pad inside a room);
                // exact containment checked by point-in-sector ray casting.
                var bbox: [Int: (Double, Double, Double, Double)] = [:]
                var fallback = -1
                for i in ss.firstSeg..<(ss.firstSeg + ss.segCount) {
                    let seg = segs[i]
                    let ld = linedefs[seg.linedef]
                    let sdIdx = seg.side < ld.sidedef.count ? ld.sidedef[seg.side] : -1
                    guard sdIdx >= 0 else { continue }
                    let sector = sidedefs[sdIdx].sector
                    if fallback < 0 { fallback = sdIdx }
                    if bbox[sector] == nil {
                        bbox[sector] = (.infinity, .infinity, -.infinity, -.infinity)
                    }
                    let v1 = vertexes[seg.v1].vec, v2 = vertexes[seg.v2].vec
                    var bb = bbox[sector]!
                    bb.0 = min(bb.0, min(v1.x.double, v2.x.double))
                    bb.1 = min(bb.1, min(v1.y.double, v2.y.double))
                    bb.2 = max(bb.2, max(v1.x.double, v2.x.double))
                    bb.3 = max(bb.3, max(v1.y.double, v2.y.double))
                    bbox[sector] = bb
                }
                let candidates = bbox.keys.sorted { s1, s2 in
                    let a = bbox[s1]!, b = bbox[s2]!
                    return (a.2 - a.0) * (a.3 - a.1) < (b.2 - b.0) * (b.3 - b.1)
                }
                for s in candidates where pointInSector(p, sector: s) {
                    return s
                }
                return fallback >= 0 ? sidedefs[fallback].sector : 0
            }
            nodeIdx = node.childIndex(child)
        }
    }

    /// Segs of a subsector with their front/back sector indices resolved.
    public func subsectorSegs(_ ssIdx: Int) -> [(seg: Seg, front: Int, back: Int?)] {
        let ss = subsectors[ssIdx]
        var out: [(Seg, Int, Int?)] = []
        for i in ss.firstSeg..<(ss.firstSeg + ss.segCount) {
            let seg = segs[i]
            let ld = linedefs[seg.linedef]
            let frontSide = ld.sidedef[seg.side]
            let front = sidedefs[frontSide].sector
            var back: Int? = nil
            if ld.sidedef[1 - seg.side] >= 0 {
                back = sidedefs[ld.sidedef[1 - seg.side]].sector
            }
            out.append((seg, front, back))
        }
        return out
    }
}
