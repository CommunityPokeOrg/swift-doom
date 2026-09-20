// hello_mod — minimal DoomMod example.
// Load with: doom-swift play --testwad --mod Examples/hello_mod.swift
import DoomScripting

final class HelloMod: DoomMod {
    let name = "hello"
    let version = "1.0"

    func onLoad(_ ctx: ModContext) {
        ctx.console.print("[hello] hello from a runtime-compiled Swift mod!")
        ctx.events.on(.pickup) { e in
            if case .pickup(_, let t) = e {
                ctx.console.print("[hello] picked up thing type \(t)")
            }
        }
    }

    func onMapLoaded(_ ctx: ModContext, mapName: String) {
        ctx.console.print("[hello] entered \(mapName)")
    }

    func onTick(_ ctx: ModContext) {
        if ctx.world.tic == 70 {
            ctx.console.print("[hello] 2 seconds in — enjoy")
        }
    }
}

@_cdecl("doommod_create")
public func doommod_create() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(HelloMod()).toOpaque()
}
