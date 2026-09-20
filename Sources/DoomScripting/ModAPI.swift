import Foundation
import DoomEngine

// MARK: - Mod protocol

/// A mod written in Swift. Mods receive lifecycle callbacks and can
/// subscribe to world events, run console commands, and mutate the world
/// through `ModWorld` — a safe, documented surface over the engine.
///
/// Mods may be compiled into the binary (see `ModRegistry`) or compiled
/// at runtime from `.swift` files (see `ScriptCompiler`).
public protocol DoomMod: AnyObject {
    var name: String { get }
    var version: String { get }
    /// Called once after the mod is attached to a running game.
    func onLoad(_ ctx: ModContext)
    /// Called every game tic (35 Hz).
    func onTick(_ ctx: ModContext)
    /// Called after a map finishes loading.
    func onMapLoaded(_ ctx: ModContext, mapName: String)
    /// Called before the mod is detached.
    func onUnload(_ ctx: ModContext)
}

public extension DoomMod {
    var version: String { "1.0" }
    func onLoad(_ ctx: ModContext) {}
    func onTick(_ ctx: ModContext) {}
    func onMapLoaded(_ ctx: ModContext, mapName: String) {}
    func onUnload(_ ctx: ModContext) {}
}

// MARK: - Events

public enum ModEvent {
    case tic
    case mapLoaded(String)
    case thingSpawned(Int)
    case thingKilled(victim: Int, source: Int?)
    case thingDamaged(victim: Int, amount: Int, source: Int?)
    case pickup(player: Int, thingType: Int)
    case lineActivated(linedef: Int, special: Int)
    case playerFired
    case exit
}

public typealias EventToken = Int

public final class EventBus {
    private var callbacks: [EventToken: (ModEvent) -> Void] = [:]
    private var wrapped: [EventToken: (ModEvent) -> Bool] = [:]
    private var nextToken = 0

    public init() {}

    /// Subscribe to all events matching `matches`.
    @discardableResult
    public func subscribe(matching matches: @escaping (ModEvent) -> Bool,
                          handler: @escaping (ModEvent) -> Void) -> EventToken {
        let t = nextToken; nextToken += 1
        callbacks[t] = handler
        wrapped[t] = matches
        return t
    }

    public func emit(_ e: ModEvent) {
        for (tok, matches) in wrapped where matches(e) {
            callbacks[tok]?(e)
        }
    }

    public func unsubscribe(_ t: EventToken) {
        callbacks.removeValue(forKey: t)
        wrapped.removeValue(forKey: t)
    }

    /// Convenience: subscribe to a single event case (payload ignored).
    @discardableResult
    public func on(_ event: ModEventKind, handler: @escaping (ModEvent) -> Void) -> EventToken {
        subscribe(matching: { event.matches($0) }, handler: handler)
    }
}

/// Cases without payloads for simple subscriptions.
public enum ModEventKind {
    case tic, thingSpawned, thingKilled, thingDamaged, pickup,
         lineActivated, playerFired, exit, mapLoaded
    func matches(_ e: ModEvent) -> Bool {
        switch (self, e) {
        case (.tic, .tic): return true
        case (.mapLoaded, .mapLoaded): return true
        case (.thingSpawned, .thingSpawned): return true
        case (.thingKilled, .thingKilled): return true
        case (.thingDamaged, .thingDamaged): return true
        case (.pickup, .pickup): return true
        case (.lineActivated, .lineActivated): return true
        case (.playerFired, .playerFired): return true
        case (.exit, .exit): return true
        default: return false
        }
    }
}

// MARK: - Console / commands

public final class Console {
    public private(set) var log: [String] = []
    public var echo: (String) -> Void = { Swift.print($0) }
    public func print(_ s: String) {
        log.append(s)
        echo(s)
    }
}

public final class CommandRegistry {
    private var commands: [String: ([String]) -> String?] = [:]
    public init() {}

    /// Register a console command; returns true if the name was free.
    @discardableResult
    public func register(_ name: String,
                         handler: @escaping ([String]) -> String?) -> Bool {
        let key = name.lowercased()
        if commands[key] != nil { return false }
        commands[key] = handler
        return true
    }

    public func run(_ line: String) -> String? {
        let parts = line.split(separator: " ").map(String.init)
        guard let name = parts.first else { return nil }
        guard let c = commands[name.lowercased()] else {
            return "unknown command: \(name)"
        }
        return c(Array(parts.dropFirst()))
    }

    public var commandNames: [String] { commands.keys.sorted() }
}

// MARK: - ModWorld: the safe mutation surface

/// Scheduled delayed callback (in tics).
final class ScheduledTask {
    var atTic: Int
    let block: () -> Void
    init(atTic: Int, block: @escaping () -> Void) {
        self.atTic = atTic; self.block = block
    }
}

/// Proxy through which mods touch the world. Exposes a curated subset of
/// engine functionality.
public final class ModWorld {
    let world: World
    var scheduled: [ScheduledTask] = []

    init(world: World) { self.world = world }

    public var tic: Int { world.ticCount }
    public var mapName: String { world.map.name }

    // MARK: Queries

    public var playerPosition: (x: Double, y: Double, z: Double) {
        guard let m = world.player?.mobj else { return (0, 0, 0) }
        return (m.pos.x.double, m.pos.y.double, m.z.double)
    }
    public var playerAngleDegrees: Double {
        Angles.toDegrees(world.player?.mobj.angle ?? 0)
    }
    public var playerHealth: Int { world.player?.health ?? 0 }
    public var playerAmmo: Int { world.player?.ammo ?? 0 }
    public var playerSector: Int { world.player?.mobj.sector ?? 0 }
    public var levelExited: Bool { world.exited }

    /// All live things matching a doomednum (nil = all).
    public func things(ofType type: Int? = nil) -> [Int] {
        world.things.filter { !$0.dead && (type == nil || $0.type.doomedNum == type) }
            .map { $0.id }
    }
    public func thingPosition(_ id: Int) -> (x: Double, y: Double, z: Double)? {
        guard let m = thing(by: id) else { return nil }
        return (m.pos.x.double, m.pos.y.double, m.z.double)
    }
    public func thingHealth(_ id: Int) -> Int? { thing(by: id)?.health }

    public func sectorFloorHeight(_ sector: Int) -> Double {
        guard sector < world.sectors.count else { return 0 }
        return world.sectors[sector].floorHeight.double
    }
    public func sectorLight(_ sector: Int) -> Int {
        guard sector < world.sectors.count else { return 0 }
        return world.sectors[sector].light
    }
    public var sectorCount: Int { world.sectors.count }

    // MARK: Mutations

    /// Spawn a thing by doomednum at map coordinates.
    @discardableResult
    public func spawnThing(type: Int, x: Double, y: Double, angleDegrees: Double = 0) -> Int? {
        world.spawn(doomedNum: type,
                    at: Vec2(x: Fixed(x), y: Fixed(y)),
                    angle: Angles.degrees(angleDegrees))?.id
    }

    /// Kill/remove a thing.
    public func killThing(_ id: Int) {
        if let m = thing(by: id) { world.kill(m, source: nil) }
    }
    public func removeThing(_ id: Int) { thing(by: id)?.dead = true }

    /// Teleport a thing.
    public func teleportThing(_ id: Int, x: Double, y: Double) {
        guard let m = thing(by: id) else { return }
        m.pos = Vec2(x: Fixed(x), y: Fixed(y))
        m.sector = world.map.sectorAt(m.pos)
        m.z = world.sectors[m.sector].floorHeight
    }

    /// Damage a thing (or the player).
    public func damageThing(_ id: Int, amount: Int) {
        if let m = thing(by: id) { world.damage(m, amount: amount, source: nil) }
    }

    /// Change sector light level (0-255).
    public func setSectorLight(_ sector: Int, light: Int) {
        guard sector < world.sectors.count else { return }
        world.sectors[sector].light = max(0, min(255, light))
    }

    /// Change a sector's floor height instantly.
    public func setSectorFloorHeight(_ sector: Int, height: Double) {
        guard sector < world.sectors.count else { return }
        world.sectors[sector].floorHeight = Fixed(height)
    }

    /// Replace a sector's floor flat.
    public func setSectorFloorFlat(_ sector: Int, flat: String) {
        guard sector < world.sectors.count else { return }
        world.sectors[sector].floorFlat = flat.uppercased()
    }

    /// Open a door-tagged sector like a switch would.
    public func openDoor(sector: Int, speed: Double = 2, waitSeconds: Double = 4) {
        let s = world.sectors[sector]
        var lowest = s.ceilingHeight
        for ld in world.map.linedefs {
            for si in ld.sidedef where si >= 0 {
                if world.map.sidedefs[si].sector == sector {
                    let other = ld.sidedef[0] == si ? ld.sidedef[1] : ld.sidedef[0]
                    if other >= 0 {
                        let oc = world.sectors[world.map.sidedefs[other].sector].ceilingHeight
                        if oc < lowest { lowest = oc }
                    }
                }
            }
        }
        world.addThinker(DoorThinker(sector: sector, topHeight: lowest - Fixed(4),
                                   speed: Fixed(speed), waitTics: Int(waitSeconds * 35)))
    }

    /// Player inventory/status.
    public func giveHealth(_ amount: Int) {
        guard let p = world.player else { return }
        p.health = min(200, p.health + amount)
    }
    public func giveAmmo(_ amount: Int) {
        guard let p = world.player else { return }
        p.ammo = min(400, p.ammo + amount)
    }
    public func giveArmor(_ amount: Int) {
        guard let p = world.player else { return }
        p.armor = min(200, p.armor + amount)
    }
    public func hurtPlayer(_ amount: Int) {
        guard let p = world.player, let m = Optional(p.mobj) else { return }
        world.damage(m, amount: amount, source: nil)
    }
    /// Push the player (e.g. jump pads). Units: map units per tic.
    public func thrustPlayer(x: Double, y: Double) {
        guard let m = world.player?.mobj else { return }
        m.vel = Vec2(x: Fixed(x), y: Fixed(y))
    }
    public func jumpPlayer(velocity: Double) {
        guard let m = world.player?.mobj else { return }
        if m.z <= world.sectors[m.sector].floorHeight { m.vz = Fixed(velocity) }
    }
    /// Force-exit the level.
    public func exitLevel() { world.exited = true }

    /// Run `block` after `tics` game tics.
    public func schedule(afterTics tics: Int, _ block: @escaping () -> Void) {
        scheduled.append(ScheduledTask(atTic: world.ticCount + tics, block: block))
    }

    /// Distance between two points.
    public func distance(_ a: (x: Double, y: Double, z: Double),
                         to b: (x: Double, y: Double, z: Double)) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Whether a direct line of sight exists between two map points.
    public func lineOfSight(ax: Double, ay: Double, bx: Double, by: Double) -> Bool {
        world.lineOfSight(Vec2(x: Fixed(ax), y: Fixed(ay)),
                          Vec2(x: Fixed(bx), y: Fixed(by)))
    }

    func runScheduled() {
        let due = scheduled.filter { $0.atTic <= world.ticCount }
        scheduled.removeAll { $0.atTic <= world.ticCount }
        for t in due { t.block() }
    }

    private func thing(by id: Int) -> MapObject? {
        world.things.first { $0.id == id && !$0.dead }
    }
}

// MARK: - ModContext

/// Everything a mod receives: world proxy, event bus, console, commands,
/// persistent scratch storage.
public final class ModContext {
    public let world: ModWorld
    public let events = EventBus()
    public let console = Console()
    public let commands = CommandRegistry()
    /// Scratch storage for mods (per map load).
    public var storage: [String: Any] = [:]

    public init(world: World) {
        self.world = ModWorld(world: world)
    }
}
