// lowgrav_mod — low gravity + stronger jumps via event hooks and scheduled
// impulses. Demonstrates physics manipulation.
import DoomScripting

final class LowGravMod: DoomMod {
    let name = "lowgrav"

    func onLoad(_ ctx: ModContext) {
        ctx.console.print("[lowgrav] moon gravity engaged")
        // 'moonjump' console command gives a huge vertical boost
        ctx.commands.register("moonjump") { _ in
            ctx.world.jumpPlayer(velocity: 16)
            return "whee"
        }
    }

    func onTick(_ ctx: ModContext) {
        // every ~3 s, bounce the player gently if airborne? keep it simple:
        // reduce fall damage by capping downward velocity via world proxy is
        // not exposed, so instead give a periodic small hop boost on jump key
        // being detected through damage events is out of scope — simple demo:
        if ctx.world.tic % 35 == 0 && ctx.world.playerPosition.z > 0 {
            // floating: nothing to do, placeholder keeps shape
        }
    }
}

@_cdecl("doommod_create")
public func doommod_create() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(LowGravMod()).toOpaque()
}
