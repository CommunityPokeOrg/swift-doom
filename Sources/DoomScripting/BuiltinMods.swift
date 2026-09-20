import Foundation
import DoomEngine

// MARK: - Built-in example mods
//
// These demonstrate the DoomMod API and are also exercised by tests.
// Runtime-compiled examples live in Examples/.

/// Prints a banner and counts kills.
public final class StatsMod: DoomMod {
    public let name = "stats"
    public private(set) var kills = 0
    public init() {}
    public func onLoad(_ ctx: ModContext) {
        ctx.console.print("[stats] mod loaded")
        ctx.events.on(.thingKilled) { [weak self] _ in
            self?.kills += 1
        }
    }
}

/// `god` command: toggles pseudo-godmode by topping up health every tic.
public final class GodMod: DoomMod {
    public let name = "god"
    private var enabled = false
    private weak var ctxRef: ModContext?
    public init() {}
    public func onLoad(_ ctx: ModContext) {
        ctxRef = ctx
        ctx.commands.register("god") { [weak self] _ in
            self?.enabled.toggle()
            return "god mode \(self?.enabled == true ? "ON" : "OFF")"
        }
    }
    public func onTick(_ ctx: ModContext) {
        if enabled { ctx.world.giveHealth(1) }
    }
}

/// A monster spawner: keeps at least `target` monsters alive by spawning
/// imps near the player every few seconds.
public final class ImpRushMod: DoomMod {
    public let name = "imp-rush"
    public var target = 4
    public init() {}
    public func onLoad(_ ctx: ModContext) {
        ctx.console.print("[imp-rush] spawn pressure enabled")
    }
    public func onTick(_ ctx: ModContext) {
        guard ctx.world.tic % 70 == 0 else { return }
        let alive = ctx.world.things(ofType: 3001).count
        guard alive < target else { return }
        let p = ctx.world.playerPosition
        let a = Double(ctx.world.tic) * 0.7
        let x = p.x + cos(a) * 150, y = p.y + sin(a) * 150
        if ctx.world.spawnThing(type: 3001, x: x, y: y, angleDegrees: a * 57.3) != nil {
            ctx.console.print("[imp-rush] imp spawned at \(Int(x)),\(Int(y))")
        }
    }
}
