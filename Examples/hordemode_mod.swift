// hordemode_mod — keeps spawning imps, opens doors when you kill enough.
// Demonstrates: events, scheduled tasks, sector manipulation, commands.
import DoomScripting

final class HordeMod: DoomMod {
    let name = "horde-mode"
    var kills = 0

    func onLoad(_ ctx: ModContext) {
        ctx.console.print("[horde] survive! kills open doors")

        ctx.events.on(.thingKilled) { [weak self] _ in
            guard let self else { return }
            self.kills += 1
            ctx.console.print("[horde] kill \(self.kills)")
            if self.kills == 3 {
                // reward: open the door sector (sector 2 in the test map)
                ctx.world.openDoor(sector: 2, speed: 3, waitSeconds: 60)
                ctx.console.print("[horde] door unlocked!")
            }
            if self.kills % 2 == 0 {
                // reinforcements
                let p = ctx.world.playerPosition
                ctx.world.schedule(afterTics: 35) {
                    _ = ctx.world.spawnThing(type: 3001, x: p.x + 120, y: p.y)
                }
            }
        }

        ctx.commands.register("horde") { _ in
            let p = ctx.world.playerPosition
            for i in 0..<3 {
                _ = ctx.world.spawnThing(type: 3001,
                                         x: p.x + 100 + Double(i) * 30,
                                         y: p.y + Double(i) * 40)
            }
            return "spawned 3 imps"
        }
    }
}

@_cdecl("doommod_create")
public func doommod_create() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(HordeMod()).toOpaque()
}
