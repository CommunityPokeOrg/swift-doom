import XCTest
@testable import DoomScripting
import DoomEngine

final class ScriptingTests: XCTestCase {

    func makeWorld() throws -> (World, ModHost) {
        let wad = try WadFile(data: TestWad.build())
        let game = Game(wad: wad)
        let world = try game.loadMap("E1M1")
        return (world, ModHost(world: world))
    }

    func testBuiltinModLoadsAndTicks() throws {
        let (world, host) = try makeWorld()
        let stats = StatsMod()
        host.load(stats)
        host.mapLoaded(name: "E1M1")
        for _ in 0..<10 { world.tic(); host.tick() }
        XCTAssertEqual(stats.kills, 0)
    }

    func testCommands() throws {
        let (_, host) = try makeWorld()
        host.load(GodMod())
        let out = host.context.commands.run("god")
        XCTAssertEqual(out, "god mode ON")
        XCTAssertEqual(host.context.commands.run("bogus"), "unknown command: bogus")
    }

    func testWorldProxySpawnAndKill() throws {
        let (world, host) = try makeWorld()
        let id = host.context.world.spawnThing(type: 3001, x: 200, y: 256)
        XCTAssertNotNil(id)
        XCTAssertNotNil(host.context.world.thingPosition(id!))
        host.context.world.killThing(id!)
        XCTAssertNil(host.context.world.thingPosition(id!)?.x as Double? ?? nil)
        _ = world
    }

    func testEvents() throws {
        let (world, host) = try makeWorld()
        var gotKill = false
        host.context.events.on(.thingKilled) { _ in gotKill = true }
        let imp = world.things.first { $0.isMonster }!
        world.kill(imp, source: nil)
        XCTAssertTrue(gotKill)
    }

    func testScheduledTask() throws {
        let (world, host) = try makeWorld()
        var fired = false
        host.context.world.schedule(afterTics: 5) { fired = true }
        for _ in 0..<10 { world.tic(); host.tick() }
        XCTAssertTrue(fired)
    }

    /// Compiles an actual .swift mod file with swiftc and loads it via dlopen.
    /// Skipped when the toolchain/modules dir is unavailable.
    func testRuntimeCompiledMod() throws {
        let src = """
        import DoomScripting
        import DoomEngine

        final class DynaMod: DoomMod {
            let name = "dyna"
            var ticks = 0
            func onLoad(_ ctx: ModContext) {
                ctx.storage["loaded"] = true
                ctx.console.print("[dyna] hi from a runtime-compiled mod")
            }
            func onTick(_ ctx: ModContext) { ticks += 1 }
        }

        @_cdecl("doommod_create")
        public func doommod_create() -> UnsafeMutableRawPointer {
            Unmanaged.passRetained(DynaMod()).toOpaque()
        }
        """
        let dir = NSTemporaryDirectory()
        let path = dir + "dyna_mod_test.swift"
        try src.write(toFile: path, atomically: true, encoding: .utf8)
        guard let mdir = ScriptCompiler.findModulesDir() else {
            throw XCTSkip("DoomScripting.swiftmodule not found — run from a built package dir")
        }
        let mod = try ScriptCompiler.compileAndLoad(path: path, modulesDir: mdir)
        XCTAssertEqual(mod.name, "dyna")

        let (world, host) = try makeWorld()
        host.load(mod)
        for _ in 0..<5 { world.tic(); host.tick() }
        XCTAssertEqual(host.context.storage["loaded"] as? Bool, true)
    }
}
