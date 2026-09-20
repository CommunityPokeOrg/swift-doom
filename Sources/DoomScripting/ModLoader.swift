import Foundation
import DoomEngine

/// Registry for built-in (compile-time) mods.
public final class ModRegistry {
    public static let shared = ModRegistry()
    public private(set) var mods: [DoomMod] = []
    private init() {}

    public func register(_ mod: DoomMod) { mods.append(mod) }
    public func clear() { mods.removeAll() }
}

/// Hosts mods for one running game: owns the shared ModContext, forwards
/// world events, ticks the mods.
public final class ModHost {
    public let context: ModContext
    public private(set) var loaded: [DoomMod] = []

    public init(world: World) {
        self.context = ModContext(world: world)
        world.onEvent = { [weak self] e in
            guard let self else { return }
            switch e {
            case .thingSpawned(let id): self.context.events.emit(.thingSpawned(id))
            case .thingKilled(let v, let s): self.context.events.emit(.thingKilled(victim: v, source: s))
            case .thingDamaged(let v, let a, let s):
                self.context.events.emit(.thingDamaged(victim: v, amount: a, source: s))
            case .pickup(let p, let t): self.context.events.emit(.pickup(player: p, thingType: t))
            case .lineActivated(let l, let s):
                self.context.events.emit(.lineActivated(linedef: l, special: s))
            case .playerFired: self.context.events.emit(.playerFired)
            case .exit: self.context.events.emit(.exit)
            }
        }
    }

    public func load(_ mod: DoomMod) {
        loaded.append(mod)
        mod.onLoad(context)
    }

    public func mapLoaded(name: String) {
        for m in loaded { m.onMapLoaded(context, mapName: name) }
        context.events.emit(.mapLoaded(name))
    }

    /// Call once per game tic.
    public func tick() {
        context.world.runScheduled()
        context.events.emit(.tic)
        for m in loaded { m.onTick(context) }
    }

    public func unloadAll() {
        for m in loaded { m.onUnload(context) }
        loaded.removeAll()
    }
}
