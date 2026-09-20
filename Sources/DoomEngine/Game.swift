import Foundation

// MARK: - Things

public enum MobjFlags {
    public static let special: UInt32 = 1       // pickup on touch
    public static let solid: UInt32 = 2
    public static let shootable: UInt32 = 4
    public static let countKill: UInt32 = 0x40
    public static let noGravity: UInt32 = 0x200
}

/// Thing-type table entry describing how a THING behaves in the world.
public struct ThingType {
    public var doomedNum: Int
    public var sprite: String        // sprite base name (e.g. "IMPA")
    public var health: Int
    public var radius: Fixed
    public var height: Fixed
    public var flags: UInt32
    public var speed: Fixed
    /// Monster melee damage per hit, 0 = harmless.
    public var damage: Int

    public init(doomedNum: Int, sprite: String, health: Int, radius: Int,
                height: Int, flags: UInt32, speed: Int = 0, damage: Int = 0) {
        self.doomedNum = doomedNum
        self.sprite = sprite
        self.health = health
        self.radius = Fixed(Int32(radius))
        self.height = Fixed(Int32(height))
        self.flags = flags
        self.speed = Fixed(Int32(speed))
        self.damage = damage
    }
}

/// Built-in thing table. Uses the classic DOOM editor numbers so ordinary
/// PWAD maps work; all data here is a functional convention, not assets.
public enum ThingTable {
    public static let types: [Int: ThingType] = [
        1:    ThingType(doomedNum: 1, sprite: "PLAY", health: 100, radius: 16, height: 56, flags: 0),
        3001: ThingType(doomedNum: 3001, sprite: "IMPA", health: 60, radius: 20, height: 56,
                        flags: MobjFlags.solid | MobjFlags.shootable | MobjFlags.countKill,
                        speed: 4, damage: 8),
        3002: ThingType(doomedNum: 3002, sprite: "DMAA", health: 150, radius: 30, height: 56,
                        flags: MobjFlags.solid | MobjFlags.shootable | MobjFlags.countKill,
                        speed: 6, damage: 12),
        2035: ThingType(doomedNum: 2035, sprite: "BARA", health: 20, radius: 10, height: 42,
                        flags: MobjFlags.solid | MobjFlags.shootable),
        2011: ThingType(doomedNum: 2011, sprite: "STIA", health: 0, radius: 20, height: 16,
                        flags: MobjFlags.special),
        2012: ThingType(doomedNum: 2012, sprite: "MEDA", health: 0, radius: 20, height: 16,
                        flags: MobjFlags.special),
        2014: ThingType(doomedNum: 2014, sprite: "BONA", health: 0, radius: 20, height: 16,
                        flags: MobjFlags.special),
        2015: ThingType(doomedNum: 2015, sprite: "BONB", health: 0, radius: 20, height: 16,
                        flags: MobjFlags.special),
        2018: ThingType(doomedNum: 2018, sprite: "ARMA", health: 0, radius: 20, height: 16,
                        flags: MobjFlags.special),
        2007: ThingType(doomedNum: 2007, sprite: "CLPA", health: 0, radius: 20, height: 16,
                        flags: MobjFlags.special),
    ]

    public static func lookup(_ num: Int) -> ThingType? { types[num] }
}

// MARK: - Map objects

public var nextMobjID = 0

public final class MapObject {
    public let id: Int
    public var pos: Vec2
    public var z: Fixed          // feet height
    public var angle: Angle
    public var vel = Vec2.zero   // xy momentum per tic
    public var vz: Fixed = .zero // vertical momentum
    public var type: ThingType
    public var health: Int
    public var flags: UInt32
    public var sector: Int
    public var target: MapObject?
    public var reactionTime: Int = 0
    public var moveCountdown: Int = 0
    public var dead = false
    /// Sprite frame override (default first loaded frame letter).
    public var spriteFrame: String = "A1"

    public init(type: ThingType, pos: Vec2, angle: Angle, sector: Int) {
        self.id = nextMobjID; nextMobjID += 1
        self.type = type
        self.pos = pos
        self.z = .zero
        self.angle = angle
        self.health = type.health
        self.flags = type.flags
        self.sector = sector
    }

    public var radius: Fixed { type.radius }
    public var height: Fixed { type.height }
    public var isMonster: Bool { flags & MobjFlags.countKill != 0 && health > 0 && !dead }
}

// MARK: - Player

public struct InputButtons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let forward = InputButtons(rawValue: 1 << 0)
    public static let back = InputButtons(rawValue: 1 << 1)
    public static let turnLeft = InputButtons(rawValue: 1 << 2)
    public static let turnRight = InputButtons(rawValue: 1 << 3)
    public static let strafeLeft = InputButtons(rawValue: 1 << 4)
    public static let strafeRight = InputButtons(rawValue: 1 << 5)
    public static let use = InputButtons(rawValue: 1 << 6)
    public static let fire = InputButtons(rawValue: 1 << 7)
    public static let run = InputButtons(rawValue: 1 << 8)
    public static let jump = InputButtons(rawValue: 1 << 9)
}

public final class Player {
    public let mobj: MapObject
    public var health = 100
    public var armor = 0
    public var ammo = 50
    public var buttons: InputButtons = []
    public var attackCooldown = 0
    /// view height above feet
    public var viewHeight: Fixed = Fixed(41)
    public init(mobj: MapObject) { self.mobj = mobj }
    public var alive: Bool { health > 0 }
}

// MARK: - Thinkers / sector actions

public protocol Thinker: AnyObject {
    /// Return false to remove the thinker.
    func think(world: World) -> Bool
}

/// Vertical door/lift mover for a sector's ceiling.
public final class DoorThinker: Thinker {
    public enum Direction { case opening, waiting, closing }
    let sector: Int
    let topHeight: Fixed
    let speed: Fixed
    let waitTics: Int
    var direction = Direction.opening
    var wait = 0
    public init(sector: Int, topHeight: Fixed, speed: Fixed, waitTics: Int) {
        self.sector = sector; self.topHeight = topHeight
        self.speed = speed; self.waitTics = waitTics
    }
    public func think(world: World) -> Bool {
        var s = world.sectors[sector]
        switch direction {
        case .opening:
            s.ceilingHeight += speed
            if s.ceilingHeight >= topHeight {
                s.ceilingHeight = topHeight
                direction = .waiting; wait = waitTics
            }
        case .waiting:
            wait -= 1
            if wait <= 0 { direction = .closing }
        case .closing:
            s.ceilingHeight -= speed
            if s.ceilingHeight <= s.floorHeight {
                s.ceilingHeight = s.floorHeight
                world.sectors[sector] = s
                return false
            }
        }
        world.sectors[sector] = s
        return true
    }
}

/// Light effect (strobe / flicker / glow) applied to a sector.
public final class LightThinker: Thinker {
    let sector: Int
    let minLight: Int
    let maxLight: Int
    let period: Int
    let mode: Mode
    var t = 0
    public enum Mode { case strobe, glow, flicker }
    public init(sector: Int, minLight: Int, maxLight: Int, period: Int, mode: Mode) {
        self.sector = sector; self.minLight = minLight; self.maxLight = maxLight
        self.period = max(1, period); self.mode = mode
    }
    public func think(world: World) -> Bool {
        t += 1
        var s = world.sectors[sector]
        switch mode {
        case .strobe:
            s.light = (t / period) % 2 == 0 ? maxLight : minLight
        case .glow:
            let ph = Double(t % (period * 2)) / Double(period)
            let k = ph < 1 ? ph : 2 - ph
            s.light = minLight + Int(k * Double(maxLight - minLight))
        case .flicker:
            s.light = (t % period) < period - 2 ? maxLight : minLight
        }
        world.sectors[sector] = s
        return true
    }
}

// MARK: - World

/// Mutable sector data wrapper — world mutates sectors for doors/lights.
public final class MapRuntime {
    public let map: MapData
    public var sectors: [Sector]
    public init(map: MapData) {
        self.map = map
        self.sectors = map.sectors
    }
}

public final class World {
    public let runtime: MapRuntime
    public var map: MapData { runtime.map }
    /// Live sector state (doors move these).
    public var sectors: [Sector] {
        get { runtime.sectors }
        set { runtime.sectors = newValue }
    }
    public private(set) var things: [MapObject] = []
    public private(set) var thinkers: [Thinker] = []
    public private(set) var ticCount = 0
    public private(set) var player: Player?
    public var exited = false
    public var rngState: UInt32 = 0x1234_5678

    /// Event hook — DoomScripting subscribes here; engine stays dependency-free.
    public var onEvent: (WorldEvent) -> Void = { _ in }

    public enum WorldEvent {
        case thingSpawned(Int)
        case thingKilled(victim: Int, source: Int?)
        case thingDamaged(victim: Int, amount: Int, source: Int?)
        case pickup(player: Int, thingType: Int)
        case lineActivated(linedef: Int, special: Int)
        case playerFired
        case exit
    }

    public init(map: MapData) {
        self.runtime = MapRuntime(map: map)
        for t in map.things { spawnFromMapThing(t) }
        startSectorSpecials()
    }

    // MARK: Spawning

    @discardableResult
    func spawnFromMapThing(_ t: MapThing) -> MapObject? {
        guard let type = ThingTable.lookup(t.type) else { return nil }
        let pos = Vec2(x: t.x, y: t.y)
        let sector = map.sectorAt(pos)
        let mo = MapObject(type: type, pos: pos, angle: t.angle, sector: sector)
        mo.z = sectors[sector].floorHeight
        things.append(mo)
        if t.type == 1 {
            player = Player(mobj: mo)
            mo.health = 100
        }
        onEvent(.thingSpawned(mo.id))
        return mo
    }

    @discardableResult
    public func spawn(doomedNum: Int, at pos: Vec2, angle: Angle = 0) -> MapObject? {
        guard let type = ThingTable.lookup(doomedNum) else { return nil }
        let sector = map.sectorAt(pos)
        let mo = MapObject(type: type, pos: pos, angle: angle, sector: sector)
        mo.z = sectors[sector].floorHeight
        things.append(mo)
        onEvent(.thingSpawned(mo.id))
        return mo
    }

    public func addThinker(_ t: Thinker) { thinkers.append(t) }

    // MARK: Damage / death

    public func damage(_ victim: MapObject, amount: Int, source: MapObject?) {
        guard !victim.dead else { return }
        if victim === player?.mobj {
            var dmg = amount
            if player!.armor > 0 {
                let absorbed = min(dmg / 3, player!.armor)
                player!.armor -= absorbed
                dmg -= absorbed
            }
            player!.health -= dmg
            onEvent(.thingDamaged(victim: victim.id, amount: dmg, source: source?.id))
            if player!.health <= 0 {
                player!.health = 0
                kill(victim, source: source)
            }
            return
        }
        guard victim.flags & MobjFlags.shootable != 0 else { return }
        victim.health -= amount
        onEvent(.thingDamaged(victim: victim.id, amount: amount, source: source?.id))
        if let s = source { victim.target = s }
        victim.reactionTime = 8 // pain chance-ish pause
        if victim.health <= 0 { kill(victim, source: source) }
    }

    public func kill(_ victim: MapObject, source: MapObject?) {
        guard !victim.dead else { return }
        victim.dead = true
        victim.flags &= ~MobjFlags.shootable
        victim.flags &= ~MobjFlags.solid
        onEvent(.thingKilled(victim: victim.id, source: source?.id))
    }

    // MARK: Geometry helpers

    public func floorHeight(at p: Vec2) -> Fixed {
        sectors[map.sectorAt(p)].floorHeight
    }
    public func ceilingHeight(at p: Vec2) -> Fixed {
        sectors[map.sectorAt(p)].ceilingHeight
    }

    /// Is movement of `mo` to `np` blocked by the given linedef?
    func lineBlocks(_ ld: Linedef, mo: MapObject, np: Vec2) -> Bool {
        if ld.flags & LineFlags.blocking != 0 { return true }
        if mo.isMonster && ld.flags & LineFlags.blockMonsters != 0 { return true }
        guard ld.sidedef[0] >= 0 && ld.sidedef[1] >= 0 else { return true } // one-sided
        // two-sided: blocked if can't step up or ceiling too low
        let front = sectors[map.sidedefs[ld.sidedef[0]].sector]
        let back = sectors[map.sidedefs[ld.sidedef[1]].sector]
        let oldSide = lineSide(map.vertexes[ld.v1].vec, map.vertexes[ld.v2].vec, mo.pos)
        let target = oldSide <= 0 ? back : front // sector on the side we are entering
        let stepUp = target.floorHeight - mo.z
        let headroom = target.ceilingHeight - target.floorHeight
        if stepUp > Fixed(24) { return true }
        if headroom < mo.height { return true }
        if target.ceilingHeight - mo.z < mo.height { return true }
        return false
    }

    /// Move `mo` by delta with line sliding + thing collision. Returns actual
    /// applied movement.
    @discardableResult
    public func move(_ mo: MapObject, delta: Vec2) -> Vec2 {
        var remaining = delta
        for _ in 0..<3 {
            if remaining.x.raw == 0 && remaining.y.raw == 0 { break }
            let np = Vec2(x: mo.pos.x + remaining.x, y: mo.pos.y + remaining.y)
            var blockedBy: Linedef? = nil
            let r = mo.radius
            let candidates = map.blockLines(minx: min(mo.pos.x, np.x) - r,
                                            miny: min(mo.pos.y, np.y) - r,
                                            maxx: max(mo.pos.x, np.x) + r,
                                            maxy: max(mo.pos.y, np.y) + r)
            for li in candidates {
                let ld = map.linedefs[li]
                let a = map.vertexes[ld.v1].vec, b = map.vertexes[ld.v2].vec
                // crossing test: endpoints on opposite sides AND within radius band
                let s1 = lineSide(a, b, mo.pos)
                let s2 = lineSide(a, b, np)
                if s1 != s2 && s1 != 0 && s2 != 0 {
                    // also require the crossing point to lie on the segment
                    if segmentCrosses(a, b, from: mo.pos, to: np) {
                        if lineBlocks(ld, mo: mo, np: np) { blockedBy = ld; break }
                        // special pickup / walkover triggers
                        triggerWalkover(ld)
                    }
                }
            }
            // thing-vs-thing collision
            var blockedByThing = false
            if mo.flags & MobjFlags.special == 0 {
                for other in things where other !== mo && !other.dead {
                    if other.flags & MobjFlags.solid == 0 && other.flags & MobjFlags.special == 0 { continue }
                    let dx = np.x - other.pos.x, dy = np.y - other.pos.y
                    let rr = mo.radius + other.radius
                    if dx.abs < rr && dy.abs < rr {
                        if other.flags & MobjFlags.special != 0, mo === player?.mobj {
                            pickup(other)
                            continue
                        }
                        blockedByThing = true
                        break
                    }
                }
            }
            guard let line = blockedBy else {
                if !blockedByThing { mo.pos = np }
                if blockedByThing { mo.vel = .zero }
                break
            }
            // slide: project remaining movement onto the line direction
            let a = map.vertexes[line.v1].vec, b = map.vertexes[line.v2].vec
            let dir = b - a
            let dirLen = dir.length
            if dirLen > 0 {
                let ux = dir.x.double / dirLen, uy = dir.y.double / dirLen
                let along = remaining.x.double * ux + remaining.y.double * uy
                remaining = Vec2(x: Fixed(along * ux), y: Fixed(along * uy))
            } else {
                remaining = .zero
            }
            mo.vel = remaining
        }
        return remaining
    }

    private func segmentCrosses(_ a: Vec2, _ b: Vec2, from p: Vec2, to q: Vec2) -> Bool {
        // segment pq crosses line ab's supporting segment within extents
        let s1 = lineSide(p, q, a)
        let s2 = lineSide(p, q, b)
        return s1 != s2 || s1 == 0 || s2 == 0
    }

    private func triggerWalkover(_ ld: Linedef) {
        // W1-type specials that fire on crossing
        switch ld.special {
        case 52: exited = true; onEvent(.exit) // walk exit
        case 97: break // teleport (not implemented)
        default: break
        }
    }

    private func pickup(_ thing: MapObject) {
        guard let pl = player else { return }
        switch thing.type.doomedNum {
        case 2011: pl.health = min(pl.health + 10, 100)       // stimpack
        case 2012: pl.health = min(pl.health + 25, 100)       // medikit
        case 2014: pl.health = min(pl.health + 1, 200)        // health bonus
        case 2015: pl.armor = min(pl.armor + 1, 200)          // armor bonus
        case 2018: pl.armor = max(pl.armor, 100)              // green armor
        case 2007: pl.ammo = min(pl.ammo + 10, 400)           // clip
        default: break
        }
        thing.dead = true
        onEvent(.pickup(player: pl.mobj.id, thingType: thing.type.doomedNum))
    }

    // MARK: LOS / hitscan

    /// Line of sight between two points: clear if no blocking line intervenes.
    public func lineOfSight(_ a: Vec2, _ b: Vec2) -> Bool {
        for (i, ld) in map.linedefs.enumerated() {
            _ = i
            let la = map.vertexes[ld.v1].vec, lb = map.vertexes[ld.v2].vec
            let s1 = lineSide(la, lb, a), s2 = lineSide(la, lb, b)
            if s1 == s2 && s1 != 0 { continue }
            if !segmentCrosses(a, b, from: la, to: lb) { continue }
            let blocking = (ld.flags & LineFlags.blocking != 0)
                || ld.sidedef[0] < 0 || ld.sidedef[1] < 0
                || ld.flags & LineFlags.blockSound != 0
            if blocking {
                // heights could still allow sight — approximate: if both sides
                // exist and neither ceiling-floor gap is closed, it doesn't block
                if ld.sidedef[0] >= 0 && ld.sidedef[1] >= 0 &&
                   ld.flags & (LineFlags.blocking | LineFlags.blockSound) == 0 {
                    continue
                }
                return false
            }
        }
        return true
    }

    /// Hitscan ray; returns hit mobj or nil. Range in map units.
    @discardableResult
    public func hitscan(from mo: MapObject, range: Fixed, damage dmg: Int) -> MapObject? {
        let dir = Vec2(x: Trig.cos(mo.angle), y: Trig.sin(mo.angle))
        let end = Vec2(x: mo.pos.x + dir.x * range,
                       y: mo.pos.y + dir.y * range)
        // nearest wall distance along ray
        var wallDist = Double(range.double)
        for ld in map.linedefs {
            let a = map.vertexes[ld.v1].vec, b = map.vertexes[ld.v2].vec
            let s1 = lineSide(a, b, mo.pos), s2 = lineSide(a, b, end)
            if s1 == s2 && s1 != 0 { continue }
            if !segmentCrosses(a, b, from: mo.pos, to: end) { continue }
            let blocking = (ld.flags & LineFlags.blocking != 0)
                || ld.sidedef[0] < 0 || ld.sidedef[1] < 0
            if !blocking { continue }
            // distance from mo.pos to intersection
            if let d = raySegmentT(mo.pos, end, a, b) {
                wallDist = min(wallDist, d)
            }
        }
        var best: MapObject? = nil
        var bestDist = wallDist
        for t in things where t !== mo && !t.dead && t.flags & MobjFlags.shootable != 0 {
            let rel = t.pos - mo.pos
            let along = rel.dot(dir).double
            if along < 0 || along > bestDist { continue }
            let perp = abs(rel.cross(dir).double) // distance off ray line
            if perp < t.radius.double + 4 {
                best = t; bestDist = along
            }
        }
        if let hit = best { damage(hit, amount: dmg, source: mo) }
        return best
    }

    private func raySegmentT(_ p: Vec2, _ q: Vec2, _ a: Vec2, _ b: Vec2) -> Double? {
        let r = q - p, s = b - a
        let denom = r.cross(s).double
        if abs(denom) < 1e-9 { return nil }
        let t = (a - p).cross(s).double / denom
        let u = (a - p).cross(r).double / denom
        guard t >= 0, u >= 0, u <= 1 else { return nil }
        return t * r.length
    }

    /// "Use" action: activate the first special line within reach ahead.
    public func activateUse(_ mo: MapObject, reach: Fixed = Fixed(96)) {
        let dir = Vec2(x: Trig.cos(mo.angle), y: Trig.sin(mo.angle))
        let end = Vec2(x: mo.pos.x + dir.x * reach,
                       y: mo.pos.y + dir.y * reach)
        for (li, ld) in map.linedefs.enumerated() {
            if ld.special == 0 { continue }
            let a = map.vertexes[ld.v1].vec, b = map.vertexes[ld.v2].vec
            let s1 = lineSide(a, b, mo.pos), s2 = lineSide(a, b, end)
            if s1 == s2 && s1 != 0 { continue }
            if !segmentCrosses(a, b, from: mo.pos, to: end) { continue }
            triggerUseLine(li, ld)
            return
        }
    }

    func triggerUseLine(_ index: Int, _ ld: Linedef) {
        onEvent(.lineActivated(linedef: index, special: Int(ld.special)))
        switch ld.special {
        case 1, 26, 27, 28, 31, 32, 33, 34, 63, 117, 118:
            openDoor(tag: Int(ld.tag), linedef: index, speed: ld.special >= 117 ? Fixed(8) : Fixed(2))
        case 11:
            exited = true; onEvent(.exit)
        default: break
        }
    }

    /// Open the door sector(s) tagged by `tag`; if tag is 0, the line's own
    /// back sector is the door.
    public func openDoor(tag: Int, linedef index: Int, speed: Fixed) {
        var sectorIndices: [Int] = []
        if tag == 0 {
            // a manual door's moving sector is the adjacent sector with the
            // lowest ceiling (the closed door itself, not the corridor)
            let ld = map.linedefs[index]
            var best: Int? = nil
            var bestCeil = Fixed(raw: Int32.max)
            for sd in ld.sidedef where sd >= 0 {
                let si = map.sidedefs[sd].sector
                if sectors[si].ceilingHeight < bestCeil {
                    bestCeil = sectors[si].ceilingHeight
                    best = si
                }
            }
            if let b = best { sectorIndices.append(b) }
        } else {
            for (i, s) in sectors.enumerated() where s.tag == tag { sectorIndices.append(i) }
        }
        for si in sectorIndices {
            // door raises ceiling to lowest adjacent ceiling - 4
            var lowest = Fixed(raw: Int32.max / 4)
            for ld in map.linedefs {
                for si2 in ld.sidedef where si2 >= 0 {
                    if map.sidedefs[si2].sector == si {
                        let otherSide = ld.sidedef[0] == si2 ? ld.sidedef[1] : ld.sidedef[0]
                        if otherSide >= 0 {
                            let oc = sectors[map.sidedefs[otherSide].sector].ceilingHeight
                            if oc < lowest { lowest = oc }
                        }
                    }
                }
            }
            if lowest.raw == Int32.max / 4 {
                lowest = sectors[si].ceilingHeight + Fixed(96)
            }
            addThinker(DoorThinker(sector: si, topHeight: lowest - Fixed(4),
                                   speed: speed, waitTics: 150))
        }
    }

    private func startSectorSpecials() {
        for (i, s) in sectors.enumerated() {
            switch s.special {
            case 1: // flicker
                addThinker(LightThinker(sector: i, minLight: 64, maxLight: s.light,
                                        period: 20, mode: .flicker))
            case 2, 3, 4, 12, 13: // strobes
                addThinker(LightThinker(sector: i, minLight: 32, maxLight: s.light,
                                        period: s.special == 4 ? 10 : 35, mode: .strobe))
            case 8, 17: // glow / fire flicker
                addThinker(LightThinker(sector: i, minLight: max(0, s.light - 64),
                                        maxLight: s.light, period: 30,
                                        mode: s.special == 8 ? .glow : .flicker))
            default: break
            }
        }
    }

    // MARK: Monster AI

    private func monsterThink(_ mo: MapObject) {
        guard mo.isMonster, let pl = player, pl.alive else { return }
        if mo.reactionTime > 0 { mo.reactionTime -= 1; return }
        mo.target = pl.mobj
        let dist = (pl.mobj.pos - mo.pos).length
        if dist < 64 {
            // melee
            if ticCount % 20 == 0 && lineOfSight(mo.pos, pl.mobj.pos) {
                damage(pl.mobj, amount: mo.type.damage, source: mo)
            }
            return
        }
        if mo.moveCountdown > 0 { mo.moveCountdown -= 1; return }
        guard lineOfSight(mo.pos, pl.mobj.pos) else {
            mo.moveCountdown = 10
            return
        }
        // chase
        mo.angle = (pl.mobj.pos - mo.pos).angle
        let step = mo.type.speed
        move(mo, delta: Vec2(x: Trig.cos(mo.angle) * step,
                             y: Trig.sin(mo.angle) * step))
        mo.moveCountdown = 3
    }

    // MARK: Player physics

    private func playerThink(_ pl: Player) {
        let mo = pl.mobj
        guard pl.alive else { return }
        var wish = Vec2.zero
        let speed: Fixed = pl.buttons.contains(.run) ? Fixed(12) : Fixed(7)
        if pl.buttons.contains(.forward) {
            wish.x += Trig.cos(mo.angle) * speed
            wish.y += Trig.sin(mo.angle) * speed
        }
        if pl.buttons.contains(.back) {
            wish.x -= Trig.cos(mo.angle) * speed
            wish.y -= Trig.sin(mo.angle) * speed
        }
        if pl.buttons.contains(.strafeRight) {
            wish.x += Trig.sin(mo.angle) * speed
            wish.y -= Trig.cos(mo.angle) * speed
        }
        if pl.buttons.contains(.strafeLeft) {
            wish.x -= Trig.sin(mo.angle) * speed
            wish.y += Trig.cos(mo.angle) * speed
        }
        // turning
        let turnSpeed: Angle = pl.buttons.contains(.run) ? 0x0400_0000 / 8 : 0x0400_0000 / 10
        if pl.buttons.contains(.turnLeft) { mo.angle &+= turnSpeed }
        if pl.buttons.contains(.turnRight) { mo.angle &-= turnSpeed }
        // cap speed
        mo.vel = wish
        _ = move(mo, delta: mo.vel)
        // touching a pickup works even when standing still on it
        for other in things where other !== mo && !other.dead
            && other.flags & MobjFlags.special != 0 {
            let dx = mo.pos.x - other.pos.x, dy = mo.pos.y - other.pos.y
            if dx.abs < mo.radius + other.radius
                && dy.abs < mo.radius + other.radius {
                pickup(other)
            }
        }
        mo.sector = map.sectorAt(mo.pos)
        // vertical: gravity + floor snap
        let floor = sectors[mo.sector].floorHeight
        if pl.buttons.contains(.jump) && mo.z <= floor {
            mo.vz = Fixed(9)
        }
        mo.vz = mo.vz - Fixed(1) // gravity
        mo.z = mo.z + mo.vz
        if mo.z < floor { mo.z = floor; mo.vz = .zero }
        if mo.z > sectors[mo.sector].ceilingHeight - mo.height {
            mo.z = sectors[mo.sector].ceilingHeight - mo.height
            mo.vz = .zero
        }
        // sector floor damage
        switch sectors[mo.sector].special {
        case 5: if ticCount % 32 == 0 { pl.health = max(0, pl.health - 10) }
        case 7: if ticCount % 32 == 0 { pl.health = max(0, pl.health - 5) }
        case 16, 4: if ticCount % 32 == 0 { pl.health = max(0, pl.health - 20) }
        case 11, 12, 13, 14: break // light/end handled elsewhere
        default: break
        }
        if sectors[mo.sector].special == 11 { exited = true; onEvent(.exit) }
        // use / fire edge triggers
        if pl.buttons.contains(.use) && !prevButtons.contains(.use) {
            activateUse(mo)
        }
        if pl.buttons.contains(.fire) && pl.attackCooldown <= 0 && pl.ammo > 0 {
            pl.ammo -= 1
            pl.attackCooldown = 12
            onEvent(.playerFired)
            _ = hitscan(from: mo, range: Fixed(2048), damage: 15 + Int(rng() % 3) * 5)
        }
        if pl.attackCooldown > 0 { pl.attackCooldown -= 1 }
        prevButtons = pl.buttons
    }

    private var prevButtons: InputButtons = []

    func rng() -> UInt32 {
        rngState = rngState &* 1103515245 &+ 12345
        return rngState >> 16
    }

    // MARK: Tic

    public func tic() {
        ticCount += 1
        if let pl = player { playerThink(pl) }
        for mo in things where mo.isMonster { monsterThink(mo) }
        thinkers = thinkers.filter { $0.think(world: self) }
        // prune dead pickups fully after a while
        things.removeAll { $0.dead && $0.flags & MobjFlags.special != 0 }
    }
}

// MARK: - Game session (engine-side)

/// Owns the world for a single map and advances it at 35 tics/second.
public final class Game {
    public static let ticsPerSecond = 35
    public let wad: WadFile
    public let textures: TextureManager
    public private(set) var world: World!

    public init(wad: WadFile) {
        self.wad = wad
        self.textures = TextureManager(wad: wad)
        self.textures.loadSprites()
    }

    @discardableResult
    public func loadMap(_ name: String) throws -> World {
        let map = try MapData(wad: wad, name: name)
        world = World(map: map)
        return world
    }
}
