import Foundation

// MARK: - Minimal BSP node builder
//
// Builds SEGS / SSECTORS / NODES from linedefs. Intended for generated maps
// (test fixtures, procedural maps); real WADs ship with their own nodes and
// this builder is never used for them.

public final class SimpleNodeBuilder {
    struct BSeg {
        var x1: Double; var y1: Double; var x2: Double; var y2: Double
        var linedef: Int
        var side: Int      // 0 = front sidedef, 1 = back sidedef
        var offset: Double // distance from linedef v1 to seg start
    }

    public struct Result {
        public var segs: [Seg] = []
        public var subsectors: [SubSector] = []
        public var nodes: [MapNode] = []
        /// Extra vertices created by splits (already appended to vertex list).
        public var extraVertexes: [MapVertex] = []
    }

    /// Build nodes for a map. `vertexes`/`linedefs`/`sidedefs` come from the
    /// map being generated; new split vertices are appended to `vertexes`.
    public static func build(linedefs: [Linedef], vertexes: inout [MapVertex]) -> Result {
        var result = Result()
        var leafSegs: [BSeg] = []
        for (i, ld) in linedefs.enumerated() {
            let a = vertexes[ld.v1], b = vertexes[ld.v2]
            let front = BSeg(x1: a.x.double, y1: a.y.double,
                             x2: b.x.double, y2: b.y.double,
                             linedef: i, side: 0, offset: 0)
            leafSegs.append(front)
            if ld.sidedef[1] >= 0 {
                // back-facing seg runs opposite direction
                leafSegs.append(BSeg(x1: b.x.double, y1: b.y.double,
                                     x2: a.x.double, y2: a.y.double,
                                     linedef: i, side: 1,
                                     offset: dist(b.x.double, b.y.double, a.x.double, a.y.double)))
            }
        }
        if leafSegs.isEmpty { return result }
        var vertexIndex: [String: Int] = [:]
        for (i, v) in vertexes.enumerated() {
            vertexIndex["\(v.x.int),\(v.y.int)"] = i
        }
        // vertexIndex must let us add vertices during recursion
        var vertexLookup: [Int64: Int] = [:]
        func vidx(_ x: Double, _ y: Double) -> Int {
            let key = Int64(x.rounded()) << 32 | Int64(y.rounded()) & 0xFFFF_FFFF
            if let i = vertexLookup[key] { return i }
            if let i = vertexIndex["\(Int(x.rounded())),\(Int(y.rounded()))"] { return i }
            let nv = MapVertex(x: Fixed(Int32(x.rounded())), y: Fixed(Int32(y.rounded())))
            vertexes.append(nv)
            let idx = vertexes.count - 1
            vertexLookup[key] = idx
            vertexIndex["\(nv.x.int),\(nv.y.int)"] = idx
            return idx
        }
        _ = vidx // silence until used via closure capture below
        var segOut: [Seg] = []

        enum Side { case front, back, spanning, collinear }
        func classify(_ s: BSeg, against p: BSeg) -> Side {
            let dx = p.x2 - p.x1, dy = p.y2 - p.y1
            let c1 = dx * (s.y1 - p.y1) - dy * (s.x1 - p.x1)
            let c2 = dx * (s.y2 - p.y1) - dy * (s.x2 - p.x1)
            let eps = 0.001
            let on1 = abs(c1) < eps, on2 = abs(c2) < eps
            if on1 && on2 { return .collinear }
            // front (child 0) = right side = cross <= 0
            if c1 <= eps && c2 <= eps { return .front }
            if c1 >= -eps && c2 >= -eps { return .back }
            return .spanning
        }
        func split(_ s: BSeg, by p: BSeg) -> (BSeg, BSeg) {
            let dx = p.x2 - p.x1, dy = p.y2 - p.y1
            let sdx = s.x2 - s.x1, sdy = s.y2 - s.y1
            let denom = dx * sdy - dy * sdx
            var t = 0.5
            if abs(denom) > 1e-9 {
                t = (dx * (s.y1 - p.y1) - dy * (s.x1 - p.x1)) / denom
                t = min(max(t, 0.0001), 0.9999)
            }
            let mx = s.x1 + t * sdx, my = s.y1 + t * sdy
            let segLen = sqrt(sdx * sdx + sdy * sdy)
            let a = BSeg(x1: s.x1, y1: s.y1, x2: mx, y2: my,
                         linedef: s.linedef, side: s.side, offset: s.offset)
            let b = BSeg(x1: mx, y1: my, x2: s.x2, y2: s.y2,
                         linedef: s.linedef, side: s.side,
                         offset: s.offset + t * segLen)
            return (a, b)
        }

        // Recursive partition
        func partition(_ segs: [BSeg]) -> Int {
            func makeLeaf(_ segs: [BSeg]) -> Int {
                let ssIdx = result.subsectors.count
                let first = segOut.count
                for s in segs where s.x1 != s.x2 || s.y1 != s.y2 {
                    segOut.append(Seg(v1: vidx(s.x1, s.y1), v2: vidx(s.x2, s.y2),
                                      angle: 0, linedef: s.linedef, side: s.side,
                                      offset: Fixed(Int32(s.offset.rounded()))))
                }
                result.subsectors.append(SubSector(segCount: segOut.count - first,
                                                   firstSeg: first))
                return ssIdx | 0x8000
            }
            // leaf?
            if segs.count <= 4 {
                return makeLeaf(segs)
            }
            // choose splitter: minimize splits, balance sides; skip degenerate
            // (sub-unit) candidates
            var best: BSeg = segs[0]
            var bestScore = Int.max
            for cand in segs.prefix(24) {
                let cdx = cand.x2 - cand.x1, cdy = cand.y2 - cand.y1
                if cdx * cdx + cdy * cdy < 0.5 { continue }
                var f = 0, b = 0, sp = 0
                for s in segs {
                    let c = classify(s, against: cand)
                    if c == .front { f += 1 } else if c == .back { b += 1 } else { sp += 1 }
                }
                let score = sp * 8 + abs(f - b)
                if score < bestScore { bestScore = score; best = cand }
            }
            var front: [BSeg] = []
            var back: [BSeg] = []
            for s in segs {
                switch classify(s, against: best) {
                case .front: front.append(s)
                case .back: back.append(s)
                case .spanning:
                    let (fa, ba) = split(s, by: best)
                    let faLen = hypot(fa.x2 - fa.x1, fa.y2 - fa.y1)
                    let baLen = hypot(ba.x2 - ba.x1, ba.y2 - ba.y1)
                    if faLen < 0.75 {
                        back.append(s)   // cut lands on the endpoint; keep whole
                    } else if baLen < 0.75 {
                        front.append(s)
                    } else {
                        front.append(fa); back.append(ba)
                    }
                case .collinear:
                    // A collinear seg's front faces the side opposite its
                    // direction relative to the splitter.
                    let sdx = s.x2 - s.x1, sdy = s.y2 - s.y1
                    let pdx = best.x2 - best.x1, pdy = best.y2 - best.y1
                    if sdx * pdx + sdy * pdy > 0 { back.append(s) }
                    else { front.append(s) }
                }
            }
            // Degenerate split: nothing got classified to one side (e.g. all
            // collinear). Emit a leaf — a convex or near-convex bundle renders
            // fine without further partitioning.
            if front.isEmpty || back.isEmpty
                || front.count >= segs.count || back.count >= segs.count {
                return makeLeaf(segs)
            }
            let nodeIdx = result.nodes.count
            result.nodes.append(MapNode(x: .zero, y: .zero, dx: .zero, dy: .zero,
                                        bbox: [[], []], children: [0, 0]))
            let frontChild = partition(front)
            let backChild = partition(back)
            // bbox per child from seg extents
            func bbox(_ segs: [BSeg]) -> [Int16] {
                var minX = Double.infinity, minY = Double.infinity
                var maxX = -Double.infinity, maxY = -Double.infinity
                for s in segs {
                    minX = min(minX, s.x1, s.x2); maxX = max(maxX, s.x1, s.x2)
                    minY = min(minY, s.y1, s.y2); maxY = max(maxY, s.y1, s.y2)
                }
                // order: top(maxy), bottom(miny), left(minx), right(maxx)
                return [Int16(clamping: Int(maxY.rounded())),
                        Int16(clamping: Int(minY.rounded())),
                        Int16(clamping: Int(minX.rounded())),
                        Int16(clamping: Int(maxX.rounded()))]
            }
            result.nodes[nodeIdx] = MapNode(
                x: Fixed(Int32(best.x1.rounded())), y: Fixed(Int32(best.y1.rounded())),
                dx: Fixed(Int32((best.x2 - best.x1).rounded())),
                dy: Fixed(Int32((best.y2 - best.y1).rounded())),
                bbox: [bbox(front), bbox(back)],
                children: [UInt16(frontChild), UInt16(backChild)]
            )
            return nodeIdx
        }

        _ = partition(leafSegs)
        result.segs = segOut
        return result
    }

    private static func dist(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)).squareRoot()
    }
}

// MARK: - Test WAD fixture
//
// Builds a small, fully original WAD ("TESTWAD") in memory: a two-room map
// with a corridor, door, pillar, raised platform, exit pad, monsters, and
// pickups. All graphics are procedurally generated placeholders. Nothing is
// copied from or derived from id Software's assets.

public enum TestWad {

    public static func build() -> Data {
        var b = WadBuilder()

        // --- PLAYPAL: generated 3-3-2 palette ---
        var pal = Data()
        for i in 0..<256 {
            let r = UInt8((i >> 5) & 7) * 36
            let g = UInt8((i >> 2) & 7) * 36
            let bl = UInt8(i & 3) * 85
            pal.append(r); pal.append(g); pal.append(bl)
        }
        // a few hand-tuned entries: grayscale 8..23, red ramp 176..191
        for i in 0..<16 {
            let g = UInt8(i * 16)
            pal[(8 + i) * 3] = g; pal[(8 + i) * 3 + 1] = g; pal[(8 + i) * 3 + 2] = g
        }
        for i in 0..<16 {
            pal[(176 + i) * 3] = UInt8(255 - i * 12)
            pal[(176 + i) * 3 + 1] = UInt8(max(0, 60 - i * 4))
            pal[(176 + i) * 3 + 2] = UInt8(max(0, 40 - i * 3))
        }
        for _ in 0..<13 { pal.append(contentsOf: pal[0..<768]) } // 14 palettes total
        b.addLump("PLAYPAL", data: pal)

        // --- patches ---
        var patchNames: [String] = []
        func addPatch(_ name: String, _ img: IndexedImage) {
            patchNames.append(name)
            b.addLump(name, data: PatchDecoder.encode(img))
        }
        addPatch("W1BRICK", Self.brickTexture())
        addPatch("W2STONE", Self.stoneTexture())
        addPatch("DOORIMG", Self.doorTexture())
        addPatch("STEPIMG", Self.stepTexture())
        addPatch("SWITIMG", Self.switchTexture())

        // --- PNAMES ---
        var pnames = Data()
        pnames.append(uint32(UInt32(patchNames.count)))
        for n in patchNames {
            var nb = Data(n.utf8.prefix(8)); while nb.count < 8 { nb.append(0) }
            pnames.append(nb)
        }
        b.addLump("PNAMES", data: pnames)

        // --- TEXTURE1: each texture = single patch ---
        var texDefs = Data()
        texDefs.append(uint32(UInt32(patchNames.count)))
        var texEntries = Data()
        var texOffsets: [UInt32] = []
        var runningOfs = 4 + patchNames.count * 4
        for (i, name) in patchNames.enumerated() {
            texOffsets.append(UInt32(runningOfs))
            var e = Data()
            var nb = Data(name.utf8.prefix(8)); while nb.count < 8 { nb.append(0) }
            e.append(nb)
            e.append(uint32(0))          // masked
            let dim = Self.patchDims[i]
            e.append(uint16(UInt16(dim.0))); e.append(uint16(UInt16(dim.1)))
            e.append(uint32(0))          // columndir (obsolete)
            e.append(uint16(1))          // patch count
            // patch entry: x, y, patch index, stepdir, colormap
            e.append(int16(0)); e.append(int16(0))
            e.append(uint16(UInt16(i)))
            e.append(uint16(0)); e.append(uint16(0))
            texEntries.append(e)
            runningOfs += e.count
        }
        for o in texOffsets { texDefs.append(uint32(o)) }
        texDefs.append(texEntries)
        b.addLump("TEXTURE1", data: texDefs)

        // --- flats ---
        b.addMarker("F_START")
        b.addLump("FLAT1", data: Self.flatTexture(base: (140, 120, 90), accent: (90, 75, 55)))
        b.addLump("FLAT2", data: Self.flatTexture(base: (100, 100, 110), accent: (70, 70, 80)))
        b.addLump("NUKAGE", data: Self.nukageFlat())
        b.addLump("RFLAT", data: Self.flatTexture(base: (160, 60, 40), accent: (110, 40, 30)))
        b.addMarker("F_END")

        // --- sprites ---
        b.addMarker("S_START")
        b.addLump("IMPAA1", data: PatchDecoder.encode(Self.creatureSprite(body: (180, 90, 40), size: 48)))
        b.addLump("DMAAA1", data: PatchDecoder.encode(Self.creatureSprite(body: (200, 40, 30), size: 52)))
        b.addLump("BARAA1", data: PatchDecoder.encode(Self.barrelSprite()))
        b.addLump("STIAA1", data: PatchDecoder.encode(Self.itemSprite(color: (200, 200, 60), size: 14)))
        b.addLump("MEDAA1", data: PatchDecoder.encode(Self.itemSprite(color: (220, 220, 220), size: 18)))
        b.addLump("BONAA1", data: PatchDecoder.encode(Self.itemSprite(color: (80, 120, 220), size: 10)))
        b.addLump("BONBA1", data: PatchDecoder.encode(Self.itemSprite(color: (60, 200, 80), size: 10)))
        b.addLump("ARMAA1", data: PatchDecoder.encode(Self.itemSprite(color: (60, 160, 60), size: 20)))
        b.addLump("CLPAA1", data: PatchDecoder.encode(Self.itemSprite(color: (200, 160, 60), size: 12)))
        b.addLump("PLAYA1", data: PatchDecoder.encode(Self.creatureSprite(body: (80, 140, 80), size: 48)))
        b.addMarker("S_END")

        // --- map E1M1 ---
        let map = Self.buildMap()
        for (name, data) in map { b.addLump(name, data: data) }

        return b.build(kind: .iwad)
    }

    private static let patchDims: [(Int, Int)] = [
        (64, 72), (64, 72), (64, 72), (64, 32), (32, 32),
    ]

    // MARK: Texture generators (all original placeholder art)

    static func brickTexture() -> IndexedImage {
        var img = IndexedImage(width: 64, height: 72)
        for y in 0..<72 {
            for x in 0..<64 {
                let row = y / 9
                let off = (row % 2) * 16
                let brickX = (x + off) % 32
                let mortar = (y % 9) == 0 || brickX == 0
                img.set(x, y, mortar ? 12 : UInt8(176 + (x * 7 + y * 3) % 8))
            }
        }
        return img
    }

    static func stoneTexture() -> IndexedImage {
        var img = IndexedImage(width: 64, height: 72)
        for y in 0..<72 {
            for x in 0..<64 {
                let v = UInt8(96 + ((x * 13 + y * 29 + (x / 16) * 7) % 32) / 4)
                img.set(x, y, v)
            }
        }
        return img
    }

    static func doorTexture() -> IndexedImage {
        var img = IndexedImage(width: 64, height: 72)
        for y in 0..<72 {
            for x in 0..<64 {
                let frame = x < 3 || x > 60 || y < 3 || y > 68
                img.set(x, y, frame ? 14 : UInt8(148 + (x + y) % 6))
            }
        }
        return img
    }

    static func stepTexture() -> IndexedImage {
        var img = IndexedImage(width: 64, height: 32)
        for y in 0..<32 {
            for x in 0..<64 {
                img.set(x, y, UInt8(104 + (x / 8) % 4 + (y / 16) * 2))
            }
        }
        return img
    }

    static func switchTexture() -> IndexedImage {
        var img = IndexedImage(width: 32, height: 32)
        for y in 0..<32 {
            for x in 0..<32 {
                let d = abs(x - 16) + abs(y - 16)
                img.set(x, y, d < 8 ? 182 : 100)
            }
        }
        return img
    }

    static func flatTexture(base: (Int, Int, Int), accent: (Int, Int, Int)) -> Data {
        // find nearest palette indices procedurally — use 332 encoding
        func idx(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
            let ri = min(7, r / 36), gi = min(7, g / 36), bi = min(3, b / 85)
            return UInt8((ri << 5) | (gi << 2) | bi)
        }
        var d = Data(count: 4096)
        for y in 0..<64 {
            for x in 0..<64 {
                let tile = (x / 16 + y / 16) % 2 == 0
                d[y * 64 + x] = tile ? idx(base.0, base.1, base.2) : idx(accent.0, accent.1, accent.2)
            }
        }
        return d
    }

    static func nukageFlat() -> Data {
        var d = Data(count: 4096)
        for y in 0..<64 {
            for x in 0..<64 {
                let swirl = (x * 5 + y * 7 + ((x * x + y * y) / 64)) % 3
                d[y * 64 + x] = UInt8(120 + swirl * 8) // greenish indices in 332
            }
        }
        return d
    }

    static func creatureSprite(body: (Int, Int, Int), size: Int) -> IndexedImage {
        var img = IndexedImage(width: size, height: size + 8)
        func idx(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
            let ri = min(7, min(r, 255) / 36)
            let gi = min(7, min(g, 255) / 36)
            let bi = min(3, min(b, 255) / 85)
            return UInt8((ri << 5) | (gi << 2) | bi)
        }
        let cx = size / 2
        for y in 4..<size + 4 {
            for x in 0..<size {
                let dx = x - cx, dy = y - (size / 2 + 4)
                let bodyR = size / 2 - abs(dy) / 3
                if abs(dx) < bodyR {
                    // eyes
                    if abs(dy - (-size / 5)) < 2 && (abs(dx - bodyR / 3) < 2 || abs(dx + bodyR / 3) < 2) {
                        img.set(x, y, 23) // bright eyes
                    } else {
                        img.set(x, y, idx(body.0 - abs(dy), body.1, body.2))
                    }
                }
            }
        }
        return img
    }

    static func barrelSprite() -> IndexedImage {
        var img = IndexedImage(width: 20, height: 34)
        for y in 2..<32 {
            for x in 2..<18 {
                let band = y < 6 || y > 27 || (y > 14 && y < 18)
                img.set(x, y, band ? 60 : UInt8(96 + (x + y) % 5))
            }
        }
        return img
    }

    static func itemSprite(color: (Int, Int, Int), size: Int) -> IndexedImage {
        var img = IndexedImage(width: size + 6, height: size + 6)
        func idx(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
            let ri = min(7, r / 36), gi = min(7, g / 36), bi = min(3, b / 85)
            return UInt8((ri << 5) | (gi << 2) | bi)
        }
        let c = size / 2 + 3
        for y in 0..<size + 6 {
            for x in 0..<size + 6 {
                let d = abs(x - c) + abs(y - c)
                if d < size / 2 { img.set(x, y, idx(color.0, color.1, color.2)) }
                else if d < size / 2 + 2 { img.set(x, y, idx(color.0 / 2, color.1 / 2, color.2 / 2)) }
            }
        }
        return img
    }

    // MARK: Map geometry

    /// Builds the E1M1-equivalent test map lumps as (name, data) pairs.
    static func buildMap() -> [(String, Data)] {

        // Sectors
        struct SDef { var f: Int; var c: Int; var ff: String; var cf: String; var l: Int; var sp: Int; var tag: Int }
        var sectorDefs: [SDef] = [
            // 0: room A
            SDef(f: 0, c: 160, ff: "FLAT1", cf: "FLAT2", l: 220, sp: 0, tag: 0),
            // 1: corridor west (between room A and door)
            SDef(f: 0, c: 96, ff: "FLAT1", cf: "FLAT2", l: 190, sp: 0, tag: 0),
            // 2: door sector (closed: ceiling == floor)
            SDef(f: 0, c: 0, ff: "FLAT1", cf: "FLAT1", l: 190, sp: 0, tag: 0),
            // 3: corridor east
            SDef(f: 0, c: 96, ff: "FLAT1", cf: "FLAT2", l: 190, sp: 0, tag: 0),
            // 4: room B (raised floor)
            SDef(f: 16, c: 176, ff: "FLAT1", cf: "FLAT2", l: 230, sp: 0, tag: 0),
            // 5: nukage pit inside room B
            SDef(f: 8, c: 176, ff: "NUKAGE", cf: "FLAT2", l: 230, sp: 7, tag: 0),
            // 6: exit pad (sector special 11 = exit level)
            SDef(f: 40, c: 176, ff: "RFLAT", cf: "FLAT2", l: 255, sp: 11, tag: 0),
        ]

        // Linedefs: (v1, v2, flags, special, tag, frontSector, backSector)
        // sector refs resolved into sidedefs below
        struct L { var a: (Int, Int); var b: (Int, Int); var flags: UInt16; var sp: UInt16; var tag: UInt16
                   var front: Int?; var back: Int?; var up: String = "-"; var lo: String = "-"; var mid: String = "-" }
        var lines: [L] = []

        // DOOM convention: sidedef[0] (front) lies on the RIGHT of v1->v2.
        // Lines below are oriented accordingly.

        // Room A outer walls (front=0, one-sided)
        lines.append(L(a: (768, 0), b: (0, 0), flags: LineFlags.blocking, sp: 0, tag: 0, front: 0, mid: "W1BRICK"))
        lines.append(L(a: (0, 512), b: (768, 512), flags: LineFlags.blocking, sp: 0, tag: 0, front: 0, mid: "W1BRICK"))
        lines.append(L(a: (0, 0), b: (0, 512), flags: LineFlags.blocking, sp: 0, tag: 0, front: 0, mid: "W1BRICK"))
        // east wall of room A except corridor opening (y 192..320)
        lines.append(L(a: (768, 192), b: (768, 0), flags: LineFlags.blocking, sp: 0, tag: 0, front: 0, mid: "W1BRICK"))
        lines.append(L(a: (768, 512), b: (768, 320), flags: LineFlags.blocking, sp: 0, tag: 0, front: 0, mid: "W1BRICK"))

        // pillar in room A (one-sided column, walls face outward)
        lines.append(L(a: (320, 224), b: (384, 224), flags: LineFlags.blocking, sp: 0, tag: 0, front: 0, mid: "W2STONE"))
        lines.append(L(a: (384, 224), b: (384, 288), flags: LineFlags.blocking, sp: 0, tag: 0, front: 0, mid: "W2STONE"))
        lines.append(L(a: (384, 288), b: (320, 288), flags: LineFlags.blocking, sp: 0, tag: 0, front: 0, mid: "W2STONE"))
        lines.append(L(a: (320, 288), b: (320, 224), flags: LineFlags.blocking, sp: 0, tag: 0, front: 0, mid: "W2STONE"))

        // portal at x=768: front=roomA(0) on the west side
        lines.append(L(a: (768, 320), b: (768, 192), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 0, back: 1, up: "STEPIMG"))
        // corridor west walls (front=1 one-sided)
        lines.append(L(a: (816, 192), b: (768, 192), flags: LineFlags.blocking, sp: 0, tag: 0, front: 1, mid: "W2STONE"))
        lines.append(L(a: (768, 320), b: (816, 320), flags: LineFlags.blocking, sp: 0, tag: 0, front: 1, mid: "W2STONE"))
        // door west portal (front corridor-west, back door sector)
        lines.append(L(a: (816, 320), b: (816, 192), flags: LineFlags.twoSided, sp: 1, tag: 0,
                       front: 1, back: 2, up: "DOORIMG"))
        // door sector walls north/south (one-sided, front=door)
        lines.append(L(a: (880, 192), b: (816, 192), flags: LineFlags.blocking, sp: 0, tag: 0, front: 2, mid: "W2STONE"))
        lines.append(L(a: (816, 320), b: (880, 320), flags: LineFlags.blocking, sp: 0, tag: 0, front: 2, mid: "W2STONE"))
        // door east portal (front = door, back = corridor east)
        lines.append(L(a: (880, 320), b: (880, 192), flags: LineFlags.twoSided, sp: 1, tag: 0,
                       front: 2, back: 3, up: "DOORIMG"))
        // corridor east walls
        lines.append(L(a: (896, 192), b: (880, 192), flags: LineFlags.blocking, sp: 0, tag: 0, front: 3, mid: "W2STONE"))
        lines.append(L(a: (880, 320), b: (896, 320), flags: LineFlags.blocking, sp: 0, tag: 0, front: 3, mid: "W2STONE"))
        // portal corridor-east -> room B (step up to floor 16)
        lines.append(L(a: (896, 320), b: (896, 192), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 3, back: 4, up: "STEPIMG", lo: "STEPIMG"))

        // Room B outer walls (front=4 one-sided)
        lines.append(L(a: (1408, 64), b: (896, 64), flags: LineFlags.blocking, sp: 0, tag: 0, front: 4, mid: "W1BRICK"))
        lines.append(L(a: (1408, 512), b: (1408, 64), flags: LineFlags.blocking, sp: 0, tag: 0, front: 4, mid: "W1BRICK"))
        lines.append(L(a: (896, 512), b: (1408, 512), flags: LineFlags.blocking, sp: 0, tag: 0, front: 4, mid: "W1BRICK"))
        lines.append(L(a: (896, 320), b: (896, 512), flags: LineFlags.blocking, sp: 0, tag: 0, front: 4, mid: "W1BRICK"))
        lines.append(L(a: (896, 64), b: (896, 192), flags: LineFlags.blocking, sp: 0, tag: 0, front: 4, mid: "W1BRICK"))

        // nukage pit ring inside room B (front=5 pit, back=4 room B)
        lines.append(L(a: (1056, 160), b: (960, 160), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 5, back: 4, lo: "STEPIMG"))
        lines.append(L(a: (1056, 256), b: (1056, 160), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 5, back: 4, lo: "STEPIMG"))
        lines.append(L(a: (960, 256), b: (1056, 256), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 5, back: 4, lo: "STEPIMG"))
        lines.append(L(a: (960, 160), b: (960, 256), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 5, back: 4, lo: "STEPIMG"))

        // exit pad inside room B (front=6 pad, back=4), floor 40
        lines.append(L(a: (1376, 256), b: (1280, 256), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 6, back: 4, lo: "STEPIMG"))
        lines.append(L(a: (1376, 352), b: (1376, 256), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 6, back: 4, lo: "STEPIMG"))
        lines.append(L(a: (1280, 352), b: (1376, 352), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 6, back: 4, lo: "STEPIMG"))
        lines.append(L(a: (1280, 256), b: (1280, 352), flags: LineFlags.twoSided, sp: 0, tag: 0,
                       front: 6, back: 4, lo: "STEPIMG"))

        // Build sidedefs: two per line max
        var sidedefData = Data()
        var sidedefCount = 0
        func sidedef(sector: Int, up: String, lo: String, mid: String) -> Int {
            func tex(_ s: String) -> Data {
                var d = Data(s.utf8.prefix(8))
                while d.count < 8 { d.append(0) }
                return d
            }
            sidedefData.append(int16(0)); sidedefData.append(int16(0))
            sidedefData.append(tex(up)); sidedefData.append(tex(lo)); sidedefData.append(tex(mid))
            sidedefData.append(int16(Int16(sector)))
            sidedefCount += 1
            return sidedefCount - 1
        }
        var linedefData = Data()
        var ldStructs: [Linedef] = []
        var vertexList: [MapVertex] = []
        var vi: [String: Int] = [:]
        func gv(_ p: (Int, Int)) -> Int {
            let k = "\(p.0),\(p.1)"
            if let i = vi[k] { return i }
            vertexList.append(MapVertex(x: Fixed(Int32(p.0)), y: Fixed(Int32(p.1))))
            vi[k] = vertexList.count - 1
            return vertexList.count - 1
        }
        for l in lines {
            let fsd = l.front != nil ? sidedef(sector: l.front!, up: l.up, lo: l.lo, mid: l.mid) : -1
            let bsd = l.back != nil ? sidedef(sector: l.back!, up: l.up, lo: l.lo, mid: "-") : -1
            let v1 = gv(l.a), v2 = gv(l.b)
            linedefData.append(uint16(UInt16(v1))); linedefData.append(uint16(UInt16(v2)))
            linedefData.append(uint16(l.flags)); linedefData.append(uint16(l.sp))
            linedefData.append(uint16(l.tag))
            linedefData.append(int16(Int16(fsd))); linedefData.append(int16(Int16(bsd)))
            var ld = Linedef(v1: v1, v2: v2, flags: l.flags, special: l.sp, tag: l.tag,
                             sidedef: [fsd, bsd])
            let a = vertexList[v1].vec, bb = vertexList[v2].vec
            ld.bboxMin = Vec2(x: min(a.x, bb.x), y: min(a.y, bb.y))
            ld.bboxMax = Vec2(x: max(a.x, bb.x), y: max(a.y, bb.y))
            ldStructs.append(ld)
        }

        // Things
        var thingData = Data()
        func thing(_ x: Int, _ y: Int, _ ang: Int, _ type: Int) {
            thingData.append(int16(Int16(x))); thingData.append(int16(Int16(y)))
            thingData.append(uint16(UInt16(ang))); thingData.append(uint16(UInt16(type)))
            thingData.append(uint16(7)) // all skill levels
        }
        thing(128, 256, 0, 1)       // player start
        thing(600, 256, 180, 3001)  // imp
        thing(600, 96, 90, 3001)    // imp
        thing(1150, 300, 180, 3002) // demon
        thing(500, 420, 0, 2035)    // barrel
        thing(700, 90, 0, 2011)     // stimpack
        thing(1120, 130, 0, 2012)   // medikit
        thing(200, 400, 0, 2014)    // health bonus
        thing(220, 400, 0, 2014)
        thing(1200, 120, 0, 2018)   // green armor
        thing(450, 450, 0, 2007)    // clip
        thing(1300, 305, 0, 2015)   // armor bonus on exit pad

        // Sectors lump
        var sectorData = Data()
        for s in sectorDefs {
            sectorData.append(int16(Int16(s.f))); sectorData.append(int16(Int16(s.c)))
            var ff = Data(s.ff.utf8.prefix(8)); while ff.count < 8 { ff.append(0) }
            var cf = Data(s.cf.utf8.prefix(8)); while cf.count < 8 { cf.append(0) }
            sectorData.append(ff); sectorData.append(cf)
            sectorData.append(int16(Int16(s.l))); sectorData.append(int16(Int16(s.sp)))
            sectorData.append(int16(Int16(s.tag)))
        }

        // Vertex lump
        var vertexData = Data()
        for v in vertexList {
            vertexData.append(int16(Int16(v.x.int))); vertexData.append(int16(Int16(v.y.int)))
        }

        // Build BSP nodes
        var vertexesForBuild = vertexList
        let nb = SimpleNodeBuilder.build(linedefs: ldStructs, vertexes: &vertexesForBuild)
        // vertexes may have grown — rebuild vertex lump
        if vertexesForBuild.count != vertexList.count {
            vertexData = Data()
            for v in vertexesForBuild {
                vertexData.append(int16(Int16(v.x.int))); vertexData.append(int16(Int16(v.y.int)))
            }
        }
        var segData = Data()
        for s in nb.segs {
            segData.append(uint16(UInt16(s.v1))); segData.append(uint16(UInt16(s.v2)))
            segData.append(uint16(UInt16(s.angle >> 16)))
            segData.append(uint16(UInt16(s.linedef)))
            segData.append(int16(Int16(s.side)))
            segData.append(int16(Int16(s.offset.int)))
        }
        var ssecData = Data()
        for ss in nb.subsectors {
            ssecData.append(uint16(UInt16(ss.segCount))); ssecData.append(uint16(UInt16(ss.firstSeg)))
        }
        var nodeData = Data()
        for n in nb.nodes {
            nodeData.append(int16(Int16(n.x.int))); nodeData.append(int16(Int16(n.y.int)))
            nodeData.append(int16(Int16(n.dx.int))); nodeData.append(int16(Int16(n.dy.int)))
            for c in 0..<2 {
                for k in 0..<4 { nodeData.append(int16(n.bbox[c][k])) }
            }
            nodeData.append(uint16(n.children[0])); nodeData.append(uint16(n.children[1]))
        }

        // BLOCKMAP
        var bmData = Data()
        let bmCols = 12, bmRows = 5, bmOx = 0, bmOy = 0
        bmData.append(int16(Int16(bmOx))); bmData.append(int16(Int16(bmOy)))
        bmData.append(uint16(UInt16(bmCols))); bmData.append(uint16(UInt16(bmRows)))
        var cellOffsets = Data()
        var cellLists = Data()
        let listBase = 8 + bmCols * bmRows * 2
        for cy in 0..<bmRows {
            for cx in 0..<bmCols {
                cellOffsets.append(uint16(UInt16(listBase + cellLists.count)))
                cellLists.append(uint16(0)) // header
                let cMinX = bmOx + cx * 128, cMinY = bmOy + cy * 128
                for (li, ld) in ldStructs.enumerated() {
                    let a = vertexesForBuild[ld.v1].vec, bb = vertexesForBuild[ld.v2].vec
                    // bbox vs cell overlap
                    if max(a.x.int, bb.x.int) >= Int32(cMinX) && min(a.x.int, bb.x.int) <= Int32(cMinX + 128) &&
                       max(a.y.int, bb.y.int) >= Int32(cMinY) && min(a.y.int, bb.y.int) <= Int32(cMinY + 128) {
                        cellLists.append(uint16(UInt16(li)))
                    }
                }
                cellLists.append(uint16(0xFFFF)) // terminator
            }
        }
        bmData.append(cellOffsets); bmData.append(cellLists)

        // REJECT: all-zero (no sight optimization)
        var reject = Data()
        reject.append(Data(repeating: 0, count: 16))

        return [
            ("E1M1", Data()),
            ("THINGS", thingData),
            ("LINEDEFS", linedefData),
            ("SIDEDEFS", sidedefData),
            ("VERTEXES", vertexData),
            ("SEGS", segData),
            ("SSECTORS", ssecData),
            ("NODES", nodeData),
            ("SECTORS", sectorData),
            ("REJECT", reject),
            ("BLOCKMAP", bmData),
        ]
    }
}
