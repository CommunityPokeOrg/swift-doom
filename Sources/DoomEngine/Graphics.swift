import Foundation

/// An indexed-color image; index 255 is reserved as transparent.
public struct IndexedImage: Sendable {
    public let width: Int
    public let height: Int
    /// Column-major for sprites/patches, row-major for flats/textures —
    /// stored row-major here; index = y*width + x. 255 = transparent.
    public var pixels: [UInt8]
    public var mask: [Bool]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 255, count: width * height)
        self.mask = [Bool](repeating: false, count: width * height)
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> UInt8 {
        pixels[y * width + x]
    }
    @inline(__always)
    public func opaque(_ x: Int, _ y: Int) -> Bool {
        mask[y * width + x]
    }
    @inline(__always)
    public mutating func set(_ x: Int, _ y: Int, _ c: UInt8) {
        pixels[y * width + x] = c
        mask[y * width + x] = true
    }
}

/// 256-entry RGB palette (PLAYPAL's first palette).
public struct Palette: Sendable {
    public var colors: [(r: UInt8, g: UInt8, b: UInt8)]

    public init(data: Data) {
        colors = []
        colors.reserveCapacity(256)
        for i in 0..<256 {
            let o = i * 3
            if o + 2 < data.count {
                colors.append((data[o], data[o + 1], data[o + 2]))
            } else {
                colors.append((0, 0, 0))
            }
        }
    }

    /// Default generated palette: RGB 3-3-2 cube plus a grayscale ramp.
    /// Original placeholder — not the DOOM palette.
    public static func generated() -> Palette {
        var d = Data()
        d.reserveCapacity(768)
        for i in 0..<256 {
            let r = UInt8((i >> 5) & 7) * 36
            let g = UInt8((i >> 2) & 7) * 36
            let b = UInt8(i & 3) * 85
            d.append(r); d.append(g); d.append(b)
        }
        // brighten index 255 neighborhood not needed; index 255 = magenta for debug
        d[255 * 3] = 255; d[255 * 3 + 1] = 0; d[255 * 3 + 2] = 255
        return Palette(data: d)
    }
}

/// Decoded DOOM patch (picture) format.
public enum PatchDecoder {
    /// Decodes the classic column-post patch format into an IndexedImage.
    public static func decode(_ data: Data) -> IndexedImage {
        guard data.count >= 8 else { return IndexedImage(width: 1, height: 1) }
        let w = Int(readU16(data, 0))
        let h = Int(readU16(data, 2))
        var img = IndexedImage(width: max(w, 1), height: max(h, 1))
        guard data.count >= 8 + w * 4 else { return img }

        for col in 0..<w {
            var ofs = Int(readU32(data, 8 + col * 4))
            // walk posts
            while ofs < data.count {
                let topdelta = Int(data[ofs])
                if topdelta == 255 { break }
                guard ofs + 3 < data.count else { break }
                let length = Int(data[ofs + 1])
                let dataStart = ofs + 4 // skip pad byte at +2
                for i in 0..<length {
                    let y = topdelta + i
                    let di = dataStart + i
                    if y >= 0 && y < h && di < data.count {
                        img.set(col, y, data[di])
                    }
                }
                ofs = dataStart + length + 1 // skip trailing pad, next post
            }
        }
        return img
    }

    /// Encodes an IndexedImage to patch format (used by the test-WAD generator).
    public static func encode(_ img: IndexedImage) -> Data {
        var out = Data()
        out.append(uint16(UInt16(img.width)))
        out.append(uint16(UInt16(img.height)))
        out.append(int16(0)) // leftoffset
        out.append(int16(0)) // topoffset
        let columnDirOfs = out.count
        out.append(Data(repeating: 0, count: img.width * 4))
        var columnOfs: [UInt32] = []
        for x in 0..<img.width {
            columnOfs.append(UInt32(out.count))
            // gather runs of opaque pixels
            var y = 0
            while y < img.height {
                while y < img.height && !img.opaque(x, y) { y += 1 }
                if y >= img.height { break }
                var end = y
                while end < img.height && img.opaque(x, end) && end - y < 254 { end += 1 }
                // emit post
                out.append(UInt8(y))          // topdelta (only supports <255 offsets)
                out.append(UInt8(end - y))    // length
                out.append(0)                 // pad
                for yy in y..<end { out.append(img[x, yy]) }
                out.append(0)                 // pad
                y = end
            }
            out.append(255) // end of column
        }
        for (i, o) in columnOfs.enumerated() {
            out.replaceSubrange(columnDirOfs + i * 4..<columnDirOfs + i * 4 + 4, with: uint32(o))
        }
        return out
    }
}

/// Composited wall texture from TEXTURE1/TEXTURE2 patch lists.
public final class TextureManager {
    public let palette: Palette
    private var textureIndex: [String: IndexedImage] = [:]
    private var flatIndex: [String: IndexedImage] = [:]
    private var patchIndex: [String: IndexedImage] = [:]
    private var patchLumpIndex: [String: Int] = [:]
    public private(set) var textureNames: [String] = []

    let wad: WadFile

    public init(wad: WadFile) {
        self.wad = wad
        if let playpal = wad.lump(named: "PLAYPAL"), playpal.data.count >= 768 {
            self.palette = Palette(data: playpal.data)
        } else {
            self.palette = Palette.generated()
        }
        loadTextures()
        loadFlats()
        for (i, l) in wad.lumps.enumerated() { patchLumpIndex[l.name] = i }
    }

    private func patch(named name: String) -> IndexedImage? {
        let key = name.uppercased()
        if let p = patchIndex[key] { return p }
        guard let lump = wad.lump(named: key), !lump.data.isEmpty else { return nil }
        let img = PatchDecoder.decode(lump.data)
        patchIndex[key] = img
        return img
    }

    private func loadTextures() {
        // PNAMES: patch lookup table
        var pnames: [String] = []
        if let p = wad.lump(named: "PNAMES"), p.data.count >= 4 {
            let count = Int(readU32(p.data, 0))
            for i in 0..<count {
                let o = 4 + i * 8
                if o + 8 <= p.data.count { pnames.append(readLumpName(p.data, o)) }
            }
        }
        for dirName in ["TEXTURE1", "TEXTURE2"] {
            guard let dir = wad.lump(named: dirName), dir.data.count >= 4 else { continue }
            let numTex = Int(readU32(dir.data, 0))
            for i in 0..<numTex {
                let dirEntry = 4 + i * 4
                guard dirEntry + 4 <= dir.data.count else { break }
                let texOfs = Int(readU32(dir.data, dirEntry))
                guard texOfs + 22 <= dir.data.count else { continue }
                let name = readLumpName(dir.data, texOfs)
                let width = Int(readU16(dir.data, texOfs + 12))
                let height = Int(readU16(dir.data, texOfs + 14))
                let patchCount = Int(readU16(dir.data, texOfs + 20))
                var img = IndexedImage(width: max(width, 1), height: max(height, 1))
                for p in 0..<patchCount {
                    let po = texOfs + 22 + p * 10
                    guard po + 10 <= dir.data.count else { break }
                    let px = Int(readI16(dir.data, po))
                    let py = Int(readI16(dir.data, po + 2))
                    let pIdx = Int(readU16(dir.data, po + 4))
                    guard pIdx < pnames.count, let patch = patch(named: pnames[pIdx]) else { continue }
                    // composite
                    for cy in 0..<patch.height {
                        let dy = py + cy
                        if dy < 0 || dy >= img.height { continue }
                        for cx in 0..<patch.width {
                            let dx = px + cx
                            if dx < 0 || dx >= img.width { continue }
                            if patch.opaque(cx, cy) { img.set(dx, dy, patch[cx, cy]) }
                        }
                    }
                }
                textureIndex[name] = img
                textureNames.append(name)
            }
        }
    }

    private func loadFlats() {
        guard let range = wad.namespaceRange(start: "F_START", end: "F_END")
            ?? wad.namespaceRange(start: "FF_START", end: "FF_END") else { return }
        for i in range {
            let l = wad.lumps[i]
            if l.data.count >= 4096 {
                var img = IndexedImage(width: 64, height: 64)
                for p in 0..<4096 {
                    img.pixels[p] = l.data[p]
                    img.mask[p] = true
                }
                flatIndex[l.name] = img
            }
        }
    }

    public func texture(named name: String) -> IndexedImage? {
        textureIndex[name.uppercased()]
    }
    public func flat(named name: String) -> IndexedImage? {
        flatIndex[name.uppercased()]
    }
    /// Sprite frames keyed by base name (e.g. "TROO"), then frame letter, then rotation.
    public var spriteFrames: [String: [String: IndexedImage]] = [:]

    public func loadSprites() {
        guard let range = wad.namespaceRange(start: "S_START", end: "S_END")
            ?? wad.namespaceRange(start: "SS_START", end: "SS_END") else { return }
        for i in range {
            let l = wad.lumps[i]
            guard l.name.count >= 5, !l.data.isEmpty else { continue }
            let base = String(l.name.prefix(4))
            let frame = String(l.name.suffix(l.name.count - 4))
            spriteFrames[base, default: [:]][frame] = PatchDecoder.decode(l.data)
        }
    }
}
