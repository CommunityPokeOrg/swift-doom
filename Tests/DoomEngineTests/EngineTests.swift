import XCTest
@testable import DoomEngine
import DoomPlatform

final class WadTests: XCTestCase {
    func testWadRoundTrip() throws {
        var b = WadBuilder()
        b.addLump("FOO", data: Data([1, 2, 3]))
        b.addLump("barlumpxyz", data: Data([9])) // >8 chars: truncated to BARLUMPX
        let data = b.build()
        let wad = try WadFile(data: data)
        XCTAssertEqual(wad.kind, .pwad)
        XCTAssertEqual(wad.lumps.count, 2)
        XCTAssertEqual(wad.lump(named: "FOO")?.data, Data([1, 2, 3]))
        XCTAssertEqual(wad.lump(named: "BARLUMPX")?.name, "BARLUMPX")
        XCTAssertEqual(wad.lump(named: "BARLUMPXYZ")?.name, "BARLUMPX")
        XCTAssertNil(wad.lump(named: "NOPE"))
    }

    func testBadMagic() {
        XCTAssertThrowsError(try WadFile(data: Data("NOPExxxxxxxx".utf8)))
    }

    func testGeneratedTestWadParses() throws {
        let wad = try WadFile(data: TestWad.build())
        XCTAssertEqual(wad.kind, .iwad)
        XCTAssertNotNil(wad.lump(named: "PLAYPAL"))
        XCTAssertNotNil(wad.lump(named: "TEXTURE1"))
        XCTAssertNotNil(wad.mapLumps(named: "E1M1"))
    }
}

final class MapTests: XCTestCase {
    var map: MapData!

    override func setUpWithError() throws {
        let wad = try WadFile(data: TestWad.build())
        map = try MapData(wad: wad, name: "E1M1")
    }

    func testMapCounts() {
        XCTAssertGreaterThan(map.linedefs.count, 20)
        XCTAssertGreaterThan(map.sidedefs.count, 30)
        XCTAssertGreaterThan(map.sectors.count, 5)
        XCTAssertGreaterThan(map.segs.count, 0)
        XCTAssertGreaterThan(map.subsectors.count, 0)
        XCTAssertGreaterThan(map.nodes.count, 0)
        XCTAssertGreaterThan(map.things.count, 5)
    }

    func testSectorLookup() {
        // player start is in room A (sector 0)
        XCTAssertEqual(map.sectorAt(Vec2(x: Fixed(128), y: Fixed(256))), 0)
        // room B
        XCTAssertEqual(map.sectorAt(Vec2(x: Fixed(1200), y: Fixed(300))), 4)
        // door sector
        XCTAssertEqual(map.sectorAt(Vec2(x: Fixed(848), y: Fixed(256))), 2)
    }

    func testBlockmapHasLines() {
        XCTAssertFalse(map.blockLines(minx: Fixed(0), miny: Fixed(0),
                                      maxx: Fixed(1408), maxy: Fixed(512)).isEmpty)
    }
}

final class GameTests: XCTestCase {
    func makeWorld() throws -> World {
        let wad = try WadFile(data: TestWad.build())
        let game = Game(wad: wad)
        return try game.loadMap("E1M1")
    }

    func testPlayerSpawns() throws {
        let w = try makeWorld()
        XCTAssertNotNil(w.player)
        XCTAssertEqual(w.player?.health, 100)
    }

    func testMovementAndCollision() throws {
        let w = try makeWorld()
        let pl = w.player!
        // walk forward (east) for 2 seconds — shouldn't pass through pillar/walls
        pl.buttons = [.forward]
        for _ in 0..<70 { w.tic() }
        XCTAssertGreaterThan(pl.mobj.pos.x.double, 128)
        // keep walking to the east wall; position should clamp before x=768-ish
        for _ in 0..<200 { w.tic() }
        XCTAssertLessThan(pl.mobj.pos.x.double, 768)
    }

    func testDoorOpensOnUse() throws {
        let w = try makeWorld()
        let pl = w.player!
        // teleport player right in front of west door line (x=816, y=256)
        pl.mobj.pos = Vec2(x: Fixed(790), y: Fixed(256))
        pl.mobj.angle = 0 // face east
        w.activateUse(pl.mobj)
        let doorSec = w.sectors[2]
        // run tics — door thinker raises ceiling
        for _ in 0..<60 { w.tic() }
        XCTAssertGreaterThan(w.sectors[2].ceilingHeight.raw, doorSec.ceilingHeight.raw)
    }

    func testPickup() throws {
        let w = try makeWorld()
        let pl = w.player!
        pl.health = 50
        // telefrag the stimpack at (700,90): move player onto it
        pl.mobj.pos = Vec2(x: Fixed(700), y: Fixed(90))
        w.tic()
        XCTAssertEqual(pl.health, 60)
    }

    func testHitscanKillsImp() throws {
        let w = try makeWorld()
        let pl = w.player!
        // imp at (600,256); stand west of it facing east
        pl.mobj.pos = Vec2(x: Fixed(500), y: Fixed(256))
        pl.mobj.angle = 0
        var hit: MapObject? = nil
        for _ in 0..<30 {
            hit = w.hitscan(from: pl.mobj, range: Fixed(2048), damage: 40)
            if hit != nil { break }
        }
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit!.dead || hit!.health < 60)
    }

    func testMonsterChasesPlayer() throws {
        let w = try makeWorld()
        let imp = w.things.first { $0.type.doomedNum == 3001 }!
        let startDist = (imp.pos - w.player!.mobj.pos).length
        for _ in 0..<140 { w.tic() }
        let endDist = (imp.pos - w.player!.mobj.pos).length
        XCTAssertLessThan(endDist, startDist + 200) // moved or attacked
    }

    func testExitSector() throws {
        let w = try makeWorld()
        let pl = w.player!
        pl.mobj.pos = Vec2(x: Fixed(1330), y: Fixed(300)) // exit pad
        for _ in 0..<5 { w.tic() }
        XCTAssertTrue(w.exited)
    }
}

final class RenderTests: XCTestCase {
    func testRenderProducesFrame() throws {
        let wad = try WadFile(data: TestWad.build())
        let game = Game(wad: wad)
        let world = try game.loadMap("E1M1")
        let r = Renderer(width: 320, height: 200, textures: game.textures)
        let fb = Framebuffer(width: 320, height: 200)
        r.render(world: world, viewpoint: world.player!.mobj, into: fb)
        // not all black
        let lit = fb.pixels.filter { $0 > 20 }.count
        XCTAssertGreaterThan(lit, 5000)
        // deterministic
        let fb2 = Framebuffer(width: 320, height: 200)
        r.render(world: world, viewpoint: world.player!.mobj, into: fb2)
        XCTAssertEqual(fb.checksum(), fb2.checksum())
    }

    func testRenderFromDifferentAngles() throws {
        let wad = try WadFile(data: TestWad.build())
        let game = Game(wad: wad)
        let world = try game.loadMap("E1M1")
        let r = Renderer(width: 160, height: 100, textures: game.textures)
        let fb = Framebuffer(width: 160, height: 100)
        for deg in [0.0, 90.0, 180.0, 270.0] {
            world.player!.mobj.angle = Angles.degrees(deg)
            r.render(world: world, viewpoint: world.player!.mobj, into: fb)
            let lit = fb.pixels.filter { $0 > 20 }.count
            XCTAssertGreaterThan(lit, 500, "angle \(deg) produced too little content")
        }
    }
}

final class SessionTests: XCTestCase {
    func testHeadlessRun() throws {
        let wad = try WadFile(data: TestWad.build())
        let game = Game(wad: wad)
        _ = try game.loadMap("E1M1")
        let session = GameSession(
            game: game, renderer: Renderer(width: 160, height: 100, textures: game.textures),
            display: NullDisplay(), input: ScriptedInput(script: [
                (tics: 1, buttons: [.forward]),
            ]), audio: NullAudio())
        let fb = session.runTics(35)
        XCTAssertTrue(fb.checksum() != 0)
    }
}
