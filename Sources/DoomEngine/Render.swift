import Foundation

/// RGB888 framebuffer the renderer draws into.
public final class Framebuffer {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8] // RGB triplets

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 3)
    }

    public func clear() {
        for i in pixels.indices { pixels[i] = 0 }
    }

    @inline(__always)
    public func setPixel(_ x: Int, _ y: Int, r: UInt8, g: UInt8, b: UInt8) {
        let o = (y * width + x) * 3
        pixels[o] = r; pixels[o + 1] = g; pixels[o + 2] = b
    }

    /// Write as binary PPM (P6).
    public func ppmData() -> Data {
        var d = Data("P6 \(width) \(height) 255\n".utf8)
        d.append(contentsOf: pixels)
        return d
    }

    /// Deterministic checksum for tests.
    public func checksum() -> UInt64 {
        var h: UInt64 = 1469598103934665603
        for b in pixels {
            h ^= UInt64(b); h &*= 1099511628211
        }
        return h
    }
}

/// A point in camera space: x = right, y = forward.
private struct CamPoint {
    var fwd: Double
    var right: Double
    var wx: Double // world coords (for texcoords)
    var wy: Double
}

/// A two-sided seg's middle texture waiting to be drawn in the masked pass.
private struct MaskedColumn {
    var x: Int
    var topY: Double
    var bottomY: Double
    var depth: Double
    var tex: IndexedImage
    var u: Double
    var sectorLight: Int
    var isSprite: Bool
    var spriteTopWorld: Double = 0
    var spriteBottomWorld: Double = 0
}

/// Column/portal software renderer. Traverses the BSP front-to-back, clips
/// portal windows per column, and texture-maps walls, floors, and ceilings.
public final class Renderer {
    public let width: Int
    public let height: Int
    let textures: TextureManager
    /// Field of view in radians; 90° matches the classic renderer.
    public var fov = Double.pi / 2
    var focal: Double { Double(width) / 2 / Foundation.tan(fov / 2) }
    var horizon: Int { height / 2 }
    /// Extra view pitch offset in pixels (camera look up/down).
    public var pitchOffset = 0

    public init(width: Int = 320, height: Int = 200, textures: TextureManager) {
        self.width = width
        self.height = height
        self.textures = textures
    }

    // Per-column render state
    private var wtop: [Int] = []
    private var wbot: [Int] = []
    private var zbuf: [Double] = []
    private var pendCeil: [Int] = []   // sector index for residual ceiling
    private var pendFloor: [Int] = []
    private var masked: [MaskedColumn] = []

    // Camera
    private var camX = 0.0
    private var camY = 0.0
    private var camZ = 0.0
    private var cosA = 0.0
    private var sinA = 0.0
    private var world: World!

    /// Render the world from the player's (or any mobj's) viewpoint.
    public func render(world: World, viewpoint: MapObject, into fb: Framebuffer) {
        self.world = world
        camX = viewpoint.pos.x.double
        camY = viewpoint.pos.y.double
        let pz = viewpoint === world.player?.mobj
            ? viewpoint.z + (world.player?.viewHeight ?? Fixed(41))
            : viewpoint.z + Fixed(41)
        camZ = pz.double
        cosA = Trig.cosD(viewpoint.angle)
        sinA = Trig.sinD(viewpoint.angle)

        wtop = [Int](repeating: 0, count: width)
        wbot = [Int](repeating: height, count: width)
        zbuf = [Double](repeating: .infinity, count: width)
        pendCeil = [Int](repeating: -1, count: width)
        pendFloor = [Int](repeating: -1, count: width)
        masked = []

        // default pending sector = the one the camera stands in
        let camSector = world.map.sectorAt(viewpoint.pos)
        for x in 0..<width { pendCeil[x] = camSector; pendFloor[x] = camSector }

        traverse(nodeIndex: world.map.nodes.isEmpty ? -1 : 0, fb: fb)

        // if map has no nodes, draw every linedef as a solid seg fallback
        if world.map.nodes.isEmpty { renderAllLinedefsFallback(fb: fb) }

        finishResidualWindows(fb: fb)
        drawMasked(fb: fb)
        drawHUD(fb: fb, world: world)
    }

    // MARK: BSP traversal

    private func traverse(nodeIndex: Int, fb: Framebuffer) {
        guard nodeIndex >= 0 else { return }
        let node = world.map.nodes[nodeIndex]
        let nx = node.x.double, ny = node.y.double
        // cross = (b-a) x (p-a); front child 0 = right side (cross <= 0)
        let cross = node.dx.double * (camY - ny) - node.dy.double * (camX - nx)
        let front = cross <= 0 ? 0 : 1
        let back = 1 - front
        descend(child: node.children[front], parent: node, fb: fb)
        descend(child: node.children[back], parent: node, fb: fb)
    }

    private func descend(child: UInt16, parent: MapNode, fb: Framebuffer) {
        if child & MapNode.subsectorBit != 0 {
            renderSubsector(Int(child & ~MapNode.subsectorBit), fb: fb)
        } else {
            traverse(nodeIndex: Int(child), fb: fb)
        }
    }

    private func renderSubsector(_ idx: Int, fb: Framebuffer) {
        for (seg, front, back) in world.map.subsectorSegs(idx) {
            renderSeg(seg, front: front, back: back, fb: fb)
        }
    }

    private func renderAllLinedefsFallback(fb: Framebuffer) {
        for (i, ld) in world.map.linedefs.enumerated() {
            let seg = Seg(v1: ld.v1, v2: ld.v2, angle: 0, linedef: i, side: 0, offset: .zero)
            let front = world.map.sidedefs[ld.sidedef[0]].sector
            let back = ld.sidedef[1] >= 0 ? world.map.sidedefs[ld.sidedef[1]].sector : nil
            renderSeg(seg, front: front, back: back, fb: fb)
        }
    }

    // MARK: Seg rendering

    private func renderSeg(_ seg: Seg, front: Int, back: Int?, fb: Framebuffer) {
        let map = world.map
        let ld = map.linedefs[seg.linedef]
        let sdIdx = seg.side < ld.sidedef.count ? ld.sidedef[seg.side] : -1
        guard sdIdx >= 0, sdIdx < map.sidedefs.count else { return }
        let side = map.sidedefs[sdIdx]
        let va = map.vertexes[seg.v1].vec
        let vb = map.vertexes[seg.v2].vec

        // skip segs facing away from the camera (back-facing copies of
        // two-sided lines are drawn by their front-facing twin)
        let camPos = Vec2(x: Fixed(camX), y: Fixed(camY))
        if lineSide(va, vb, camPos) > 0 { return }

        // to camera space
        var p1 = toCam(va)
        var p2 = toCam(vb)
        let near = 0.5
        if p1.fwd < near && p2.fwd < near { return }
        // clip to near plane
        if p1.fwd < near || p2.fwd < near {
            let t = (near - p1.fwd) / (p2.fwd - p1.fwd)
            let cx = p1.right + t * (p2.right - p1.right)
            let wx = p1.wx + t * (p2.wx - p1.wx)
            let wy = p1.wy + t * (p2.wy - p1.wy)
            if p1.fwd < near { p1 = CamPoint(fwd: near, right: cx, wx: wx, wy: wy) }
            else { p2 = CamPoint(fwd: near, right: cx, wx: wx, wy: wy) }
        }
        var sx1f = Double(width) / 2 + focal * p1.right / p1.fwd
        var sx2f = Double(width) / 2 + focal * p2.right / p2.fwd
        if sx2f < sx1f { return } // degenerate
        if sx2f < 0 || sx1f >= Double(width) { return }
        let x0 = max(0, Int(sx1f.rounded(.up)))
        let x1 = min(width - 1, Int(sx2f.rounded(.down)))
        if x1 < x0 { return }

        let frontSec = world.sectors[front]
        let backSec = back.map { world.sectors[$0] }
        let isPortal = backSec != nil && ld.sidedef[0] >= 0 && ld.sidedef[1] >= 0

        // seg direction in camera space for per-column solve
        let sdx = p2.fwd - p1.fwd
        let srx = p2.right - p1.right
        let segLenWorld = sqrt(pow(p2.wx - p1.wx, 2) + pow(p2.wy - p1.wy, 2))
        let texBase = side.textureOffset.double + seg.offset.double

        let horiz = Double(horizon + pitchOffset)

        for x in x0...x1 {
            if wtop[x] >= wbot[x] { continue }
            let rx = (Double(x) - Double(width) / 2) / focal // dir right component
            // Intersect the pixel ray (camera-space dir (rx, 1)) with the seg:
            //   s*rx = p1.right + t*srx ;  s = p1.fwd + t*sdx
            //   → t*(sdx*rx - srx) = p1.right - p1.fwd*rx
            let det = sdx * rx - srx
            guard abs(det) > 1e-9 else { continue }
            let tt = (p1.right - p1.fwd * rx) / det
            let depth = p1.fwd + tt * sdx // forward component = perpendicular depth
            guard depth > 0.1, tt >= -0.001, tt <= 1.001 else { continue }

            let scale = focal / depth
            let fTop = horiz - (frontSec.ceilingHeight.double - camZ) * scale
            let fBot = horiz - (frontSec.floorHeight.double - camZ) * scale
            var openTop = fTop, openBot = fBot

            var wTopI = wtop[x]
            var wBotI = wbot[x]
            if wTopI >= wBotI { continue }

            // front ceiling span [wTopI, fTop)
            if fTop > Double(wTopI) {
                drawCeilSpan(x: x, y0: wTopI, y1: min(Int(fTop.rounded(.up)), wBotI),
                             sector: frontSec, fb: fb)
            }
            // front floor span [fBot, wBotI)
            if fBot < Double(wBotI) {
                drawFloorSpan(x: x, y0: max(Int(fBot.rounded(.down)), wTopI), y1: wBotI,
                              sector: frontSec, fb: fb)
            }

            let texU = texBase + tt * segLenWorld

            if isPortal, let b = backSec {
                let bTop = horiz - (b.ceilingHeight.double - camZ) * scale
                let bBot = horiz - (b.floorHeight.double - camZ) * scale
                openTop = max(fTop, bTop)
                openBot = min(fBot, bBot)
                // upper wall between fTop and bTop (back ceil lower)
                if bTop > fTop, let tex = textures.texture(named: side.upperTexture) {
                    drawWallColumn(x: x, y0: Int(fTop.rounded(.up)), y1: Int(bTop.rounded(.down)),
                                   tex: tex, u: texU, topWorldZ: frontSec.ceilingHeight.double,
                                   bottomWorldZ: b.ceilingHeight.double, depth: depth,
                                   pegTop: ld.flags & LineFlags.upperUnpegged == 0,
                                   light: frontSec.light, camZ: camZ, horiz: horiz, fb: fb)
                }
                // lower wall between bBot and fBot (back floor higher)
                if fBot > bBot, let tex = textures.texture(named: side.lowerTexture) {
                    drawWallColumn(x: x, y0: Int(bBot.rounded(.up)), y1: Int(fBot.rounded(.down)),
                                   tex: tex, u: texU, topWorldZ: b.floorHeight.double,
                                   bottomWorldZ: frontSec.floorHeight.double, depth: depth,
                                   pegTop: ld.flags & LineFlags.lowerUnpegged != 0,
                                   light: frontSec.light, camZ: camZ, horiz: horiz, fb: fb)
                }
                // masked mid texture
                if let tex = textures.texture(named: side.middleTexture) {
                    masked.append(MaskedColumn(x: x, topY: fTop, bottomY: fBot,
                                               depth: depth, tex: tex, u: texU,
                                               sectorLight: frontSec.light, isSprite: false,
                                               spriteTopWorld: frontSec.ceilingHeight.double,
                                               spriteBottomWorld: frontSec.floorHeight.double))
                }
                // new window + pending sectors for residual ceiling/floor
                let newTop = max(wTopI, Int(openTop.rounded(.up)))
                let newBot = min(wBotI, Int(openBot.rounded(.down)))
                wtop[x] = newTop
                wbot[x] = max(newTop, newBot)
                pendCeil[x] = back ?? front
                pendFloor[x] = back ?? front
            } else {
                // solid wall
                if let tex = textures.texture(named: side.middleTexture) {
                    drawWallColumn(x: x, y0: Int(fTop.rounded(.up)), y1: Int(fBot.rounded(.down)),
                                   tex: tex, u: texU, topWorldZ: frontSec.ceilingHeight.double,
                                   bottomWorldZ: frontSec.floorHeight.double, depth: depth,
                                   pegTop: true, light: frontSec.light,
                                   camZ: camZ, horiz: horiz, fb: fb)
                }
                zbuf[x] = depth
                wtop[x] = wBotI // close window
            }
            _ = sx1f; _ = sx2f
        }
    }

    private func toCam(_ v: Vec2) -> CamPoint {
        let dx = v.x.double - camX
        let dy = v.y.double - camY
        // forward = (cos a, sin a); right = (sin a, -cos a)
        return CamPoint(fwd: dx * cosA + dy * sinA,
                        right: dx * sinA - dy * cosA,
                        wx: v.x.double, wy: v.y.double)
    }

    // MARK: Column/span primitives

    /// Vertical textured wall slice between screen ys (exclusive), texture
    /// mapped 1 world unit = 1 texel.
    private func drawWallColumn(x: Int, y0: Int, y1: Int, tex: IndexedImage,
                                u: Double, topWorldZ: Double, bottomWorldZ: Double,
                                depth: Double, pegTop: Bool,
                                light: Int, camZ: Double, horiz: Double, fb: Framebuffer) {
        let yy0 = max(y0, wtop[x])
        let yy1 = min(y1, wbot[x] - 1)
        if yy1 < yy0 { return }
        let tx = Int(u.truncatingRemainder(dividingBy: Double(tex.width)))
        let txc = (tx + tex.width) % tex.width
        let shade = lightShade(light: light, depth: depth)
        for y in yy0...yy1 {
            // world z of this pixel's center
            let wz = camZ + (horiz - Double(y)) * depth / focal
            let vRel = pegTop ? (topWorldZ - wz) : (wz - bottomWorldZ)
            var ty = Int(vRel.truncatingRemainder(dividingBy: Double(tex.height)))
            ty = (ty + tex.height) % tex.height
            let srcY = pegTop ? ty : tex.height - 1 - ty
            guard tex.opaque(txc, srcY) else { continue }
            putIndexed(x: x, y: y, idx: tex[txc, srcY], shade: shade, fb: fb)
        }
        if depth < zbuf[x] { zbuf[x] = depth }
    }

    /// Fill ceiling pixels [y0,y1) in column x using the sector's flat.
    private func drawCeilSpan(x: Int, y0: Int, y1: Int, sector: Sector, fb: Framebuffer) {
        guard y1 > y0 else { return }
        guard let flat = textures.flat(named: sector.ceilingFlat) else {
            // sky-ish fallback for missing flat
            return
        }
        if sector.ceilingFlat == "F_SKY1" { drawSkySpan(x: x, y0: y0, y1: y1, ceiling: true, fb: fb); return }
        let rx = (Double(x) - Double(width) / 2) / focal
        let horiz = Double(horizon + pitchOffset)
        let hdiff = camZ - sector.ceilingHeight.double // camZ above? ceiling above cam → hdiff < 0
        let zAbove = sector.ceilingHeight.double - camZ
        for y in max(y0, 0)..<min(y1, height) {
            let rows = horiz - Double(y) // positive above horizon
            if rows <= 0 { continue }
            let dist = zAbove * focal / rows
            if dist <= 0 { continue }
            let wx = camX + (dirX(rx) * dist)
            let wy = camY + (dirY(rx) * dist)
            let shade = lightShade(light: sector.light, depth: dist)
            let fx = Int(wx.truncatingRemainder(dividingBy: 64))
            let fy = Int(wy.truncatingRemainder(dividingBy: 64))
            putIndexed(x: x, y: y, idx: flat[(fx + 64) % 64, (fy + 64) % 64],
                       shade: shade, fb: fb)
            _ = hdiff
        }
    }

    private func drawFloorSpan(x: Int, y0: Int, y1: Int, sector: Sector, fb: Framebuffer) {
        guard y1 > y0 else { return }
        guard let flat = textures.flat(named: sector.floorFlat) else { return }
        if sector.floorFlat == "F_SKY1" { drawSkySpan(x: x, y0: y0, y1: y1, ceiling: false, fb: fb); return }
        let rx = (Double(x) - Double(width) / 2) / focal
        let horiz = Double(horizon + pitchOffset)
        let zBelow = camZ - sector.floorHeight.double
        for y in max(y0, 0)..<min(y1, height) {
            let rows = Double(y) - horiz
            if rows <= 0 { continue }
            let dist = zBelow * focal / rows
            if dist <= 0 { continue }
            let wx = camX + dirX(rx) * dist
            let wy = camY + dirY(rx) * dist
            let shade = lightShade(light: sector.light, depth: dist)
            let fx = Int(wx.truncatingRemainder(dividingBy: 64))
            let fy = Int(wy.truncatingRemainder(dividingBy: 64))
            putIndexed(x: x, y: y, idx: flat[(fx + 64) % 64, (fy + 64) % 64],
                       shade: shade, fb: fb)
        }
    }

    private func drawSkySpan(x: Int, y0: Int, y1: Int, ceiling: Bool, fb: Framebuffer) {
        // placeholder gradient sky — deliberately not the DOOM sky texture
        for y in max(y0, 0)..<min(y1, height) {
            let k = Double(y) / Double(height)
            let r = UInt8(60 + 60 * k)
            let g = UInt8(40 + 40 * k)
            let b = UInt8(90 + 60 * k)
            fb.setPixel(x, y, r: ceiling ? r : r / 2, g: ceiling ? g : g / 2, b: b)
        }
    }

    /// World direction for screen column offset rx (camera-space (rx, 1)).
    private func dirX(_ rx: Double) -> Double { rx * (-sinA) + 1.0 * cosA }
    private func dirY(_ rx: Double) -> Double { rx * cosA + 1.0 * sinA }

    /// After all segs: fill whatever window remains per column with the
    /// pending (deepest seen) sector's ceiling/floor up to the horizon.
    private func finishResidualWindows(fb: Framebuffer) {
        for x in 0..<width {
            let top = wtop[x], bot = wbot[x]
            if top >= bot { continue }
            let horiz = horizon + pitchOffset
            if let cs = pendCeil[x] >= 0 ? world?.sectors[pendCeil[x]] : nil {
                drawCeilSpan(x: x, y0: top, y1: min(horiz, bot), sector: cs, fb: fb)
            }
            if let fs = pendFloor[x] >= 0 ? world?.sectors[pendFloor[x]] : nil {
                drawFloorSpan(x: x, y0: max(horiz, top), y1: bot, sector: fs, fb: fb)
            }
        }
    }

    /// Sprites + masked mid textures, far-to-near, clipped by wall z-buffer.
    private func drawMasked(fb: Framebuffer) {
        // collect sprites from things
        struct SpriteItem { var depth: Double; var x0: Int; var x1: Int; var top: Double; var bot: Double; var img: IndexedImage; var light: Int }
        var sprites: [SpriteItem] = []
        for mo in world.things where !mo.dead {
            if mo === world.player?.mobj { continue }
            guard let frames = textures.spriteFrames[mo.type.sprite] else { continue }
            let img = frames[mo.spriteFrame] ?? frames["A1"] ?? frames.values.first
            guard let img else { continue }
            let c = toCam(mo.pos)
            if c.fwd < 1 { continue }
            let scale = focal / c.fwd
            let cx = Double(width) / 2 + c.right * scale
            let w = Double(img.width) * scale / 64 * 64 / max(1, Double(img.width)) // 1px=1unit
            let sw = Double(img.width) * scale
            let top = Double(horizon + pitchOffset) - (mo.z.double + mo.height.double - camZ) * scale
            let bot = Double(horizon + pitchOffset) - (mo.z.double - camZ) * scale
            sprites.append(SpriteItem(depth: c.fwd,
                                      x0: Int((cx - sw / 2).rounded()),
                                      x1: Int((cx + sw / 2).rounded()),
                                      top: top, bot: bot, img: img,
                                      light: world.sectors[mo.sector].light))
            _ = w
        }
        // sort far to near; masked columns interleave with sprites
        var items: [(depth: Double, draw: (Int) -> Void)] = []
        for s in sprites {
            let sd = s.depth
            items.append((sd, { [self] _ in
                let xlo = max(0, s.x0), xhi = min(width, s.x1)
                guard xhi > xlo else { return }
                let ylo = max(0, Int(s.top.rounded())), yhi = min(height, Int(s.bot.rounded()))
                guard yhi > ylo else { return }
                for x in xlo..<xhi {
                    guard sd < zbuf[x] else { continue }
                    let u = Double(x - s.x0) / max(1.0, Double(s.x1 - s.x0))
                    let tx = max(0, min(s.img.width - 1, Int(u * Double(s.img.width))))
                    let shade = lightShade(light: s.light, depth: sd)
                    for y in ylo..<yhi {
                        let v = Double(y) - s.top
                        let ty = max(0, min(s.img.height - 1,
                                            Int(v / max(1e-9, s.bot - s.top) * Double(s.img.height))))
                        guard s.img.opaque(tx, ty) else { continue }
                        putIndexed(x: x, y: y, idx: s.img[tx, ty], shade: shade, fb: fb)
                    }
                }
            }))
        }
        for m in masked {
            let md = m.depth
            items.append((md, { [self] _ in
                let yy0 = max(Int(m.topY.rounded(.up)), wtop[m.x])
                let yy1 = min(Int(m.bottomY.rounded(.down)), wbot[m.x] - 1)
                if yy1 < yy0 { return }
                if md > zbuf[m.x] { return }
                let tx = Int(m.u.truncatingRemainder(dividingBy: Double(m.tex.width)))
                let txc = (tx + m.tex.width) % m.tex.width
                let shade = lightShade(light: m.sectorLight, depth: md)
                for y in yy0...yy1 {
                    let wz = camZ + (Double(horizon + pitchOffset) - Double(y)) * md / focal
                    var ty = Int((m.spriteTopWorld - wz).truncatingRemainder(dividingBy: Double(m.tex.height)))
                    ty = (ty + m.tex.height) % m.tex.height
                    guard m.tex.opaque(txc, ty) else { continue }
                    putIndexed(x: m.x, y: y, idx: m.tex[txc, ty], shade: shade, fb: fb)
                }
            }))
        }
        items.sort { $0.depth > $1.depth }
        for it in items { it.draw(0) }
    }

    // MARK: Shading / output

    @inline(__always)
    private func lightShade(light: Int, depth: Double) -> Double {
        // sector light 0..255 plus distance dimming
        let l = Double(light) / 255.0
        let dim = max(0.15, 1.0 - depth / 1600.0)
        return l * dim
    }

    @inline(__always)
    private func putIndexed(x: Int, y: Int, idx: UInt8, shade: Double, fb: Framebuffer) {
        let c = textures.palette.colors[Int(idx)]
        fb.setPixel(x, y,
                    r: UInt8(min(255, Double(c.r) * shade + 8)),
                    g: UInt8(min(255, Double(c.g) * shade + 8)),
                    b: UInt8(min(255, Double(c.b) * shade + 8)))
    }

    // MARK: HUD

    private func drawHUD(fb: Framebuffer, world: World) {
        guard let pl = world.player else { return }
        // health bar, bottom left
        let barW = 60, barH = 5
        let x0 = 4, y0 = height - barH - 4
        let frac = Double(pl.health) / 100.0
        for y in y0..<(y0 + barH) {
            for x in x0..<(x0 + barW) {
                let inside = x - x0 < Int(Double(barW) * frac)
                fb.setPixel(x, y,
                            r: inside ? 200 : 60,
                            g: inside ? 30 : 40,
                            b: inside ? 30 : 40)
            }
        }
        // ammo pips, bottom right
        let ax0 = width - 4 - min(pl.ammo, 40) * 2
        for i in 0..<min(pl.ammo, 40) {
            for y in y0..<(y0 + barH) { fb.setPixel(ax0 + i * 2, y, r: 200, g: 180, b: 60) }
        }
    }
}
