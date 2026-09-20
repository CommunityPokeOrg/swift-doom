import Foundation
import DoomEngine
import DoomPlatform
import DoomScripting

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    doom-swift — a DOOM engine in Swift with Swift modding support

    USAGE:
      doom-swift wadinfo <file.wad>
      doom-swift mktwad <out.wad>                  generate the built-in test WAD
      doom-swift maps <file.wad>                   list map names
      doom-swift render [--wad f.wad|--testwad] [--map E1M1] [--tics N]
                        [--out frame.ppm] [--size WxH] [--mod m.swift]...
      doom-swift play   [--wad f.wad|--testwad] [--map E1M1] [--mod m.swift]...
                        [--size WxH]
      doom-swift demo   [--tics N]                 scripted headless demo run
      doom-swift modcheck <m.swift>                compile a mod script (check only)

    Notes:
      --testwad uses the generated original fixture (no copyrighted assets).
      A real game requires a DOOM/DOOM2 IWAD you own: --wad /path/to/doom.wad
      Terminal play: w/s=move  a/d=turn  z/c=strafe  space/e=use  f=fire
                     r=run  j=jump  q=quit
    """)
    exit(1)
}

struct Options {
    var wadPath: String?
    var testwad = false
    var map = "E1M1"
    var tics = 70
    var out = "frame.ppm"
    var size = "320x200"
    var mods: [String] = []
    var modules: String?

    static func parse(_ a: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < a.count {
            let arg = a[i]
            func take() -> String { i += 1; return i < a.count ? a[i] : "" }
            switch arg {
            case "--wad": o.wadPath = take()
            case "--testwad": o.testwad = true
            case "--map": o.map = take()
            case "--tics": o.tics = Int(take()) ?? o.tics
            case "--out": o.out = take()
            case "--size": o.size = take()
            case "--mod": o.mods.append(take())
            case "--modules": o.modules = take()
            default: break
            }
            i += 1
        }
        return o
    }

    func sizeParts() -> (Int, Int) {
        let p = size.split(separator: "x").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : (320, 200)
    }
}

func loadWad(_ o: Options) throws -> WadFile {
    if o.testwad { return try WadFile(data: TestWad.build()) }
    guard let path = o.wadPath else {
        throw NSError(domain: "doom", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                        "pass --wad <file> or --testwad"])
    }
    return try WadFile(contentsOf: URL(fileURLWithPath: path))
}

func loadMods(_ paths: [String], into host: ModHost, modules: String?) {
    for p in paths {
        do {
            let mod = try ScriptCompiler.compileAndLoad(path: p, modulesDir: modules)
            host.load(mod)
            print("loaded mod: \(mod.name)")
        } catch {
            FileHandle.standardError.write("mod '\(p)' failed: \(error)\n".data(using: .utf8)!)
        }
    }
}

guard let command = args.first else { usage() }
let rest = Array(args.dropFirst())

switch command {
case "wadinfo":
    guard let path = rest.first else { usage() }
    let wad = try WadFile(contentsOf: URL(fileURLWithPath: path))
    print("kind: \(wad.kind.rawValue)  lumps: \(wad.lumps.count)")
    for l in wad.lumps.prefix(60) { print("  \(l.name)  \(l.data.count) bytes") }
    if wad.lumps.count > 60 { print("  ... \(wad.lumps.count - 60) more") }

case "mktwad":
    guard let out = rest.first else { usage() }
    let data = TestWad.build()
    try data.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) (\(data.count) bytes)")

case "maps":
    guard let path = rest.first else { usage() }
    let wad = try WadFile(contentsOf: URL(fileURLWithPath: path))
    let mapLumps: Set<String> = ["THINGS","LINEDEFS","SIDEDEFS","VERTEXES","SEGS",
                                 "SSECTORS","NODES","SECTORS","REJECT","BLOCKMAP"]
    for (i, l) in wad.lumps.enumerated() where i + 1 < wad.lumps.count {
        if mapLumps.contains(wad.lumps[i + 1].name) && !mapLumps.contains(l.name) {
            print(l.name)
        }
    }

case "render":
    let o = Options.parse(rest)
    let wad = try loadWad(o)
    let game = Game(wad: wad)
    let world = try game.loadMap(o.map)
    let (w, h) = o.sizeParts()
    let renderer = Renderer(width: w, height: h, textures: game.textures)
    let input = ScriptedInput(script: [
        (tics: 5, buttons: [.forward]), (tics: 30, buttons: [.fire]),
    ])
    let session = GameSession(game: game, renderer: renderer,
                              display: NullDisplay(), input: input, audio: NullAudio())
    let host = ModHost(world: world)
    loadMods(o.mods, into: host, modules: o.modules)
    host.mapLoaded(name: o.map)
    session.onTic = { _ in host.tick() }
    let fb = session.runTics(o.tics)
    try fb.ppmData().write(to: URL(fileURLWithPath: o.out))
    print("rendered \(o.tics) tics -> \(o.out) (\(w)x\(h)), checksum=\(fb.checksum())")

case "demo":
    let o = Options.parse(rest)
    let wad = try WadFile(data: TestWad.build())
    let game = Game(wad: wad)
    let world = try game.loadMap(o.map)
    let (w, h) = o.sizeParts()
    let renderer = Renderer(width: w, height: h, textures: game.textures)
    // scripted demo: walk forward, open the door, keep going, fire a few times
    let input = ScriptedInput(script: [
        (tics: 5, buttons: [.forward, .run]),
        (tics: 60, buttons: [.use]),
        (tics: 70, buttons: [.forward, .run]),
        (tics: 130, buttons: [.fire]),
        (tics: 160, buttons: [.forward]),
    ])
    FileManager.default.createFile(atPath: "demo-out", contents: nil)
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("demo-frames")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let display = PPMDisplay(directory: dir, every: 35)
    let session = GameSession(game: game, renderer: renderer,
                              display: display, input: input,
                              audio: WavAudio(url: dir.deletingLastPathComponent()
                                                .appendingPathComponent("demo.wav")))
    let host = ModHost(world: world)
    for m in ModRegistry.shared.mods { host.load(m) }
    loadMods(o.mods, into: host, modules: o.modules)
    host.mapLoaded(name: o.map)
    session.onTic = { _ in host.tick() }
    let fb = session.runTics(o.tics)
    try fb.ppmData().write(to: URL(fileURLWithPath: "demo-final.ppm"))
    print("demo done: \(world.ticCount) tics, frames in demo-frames/, " +
          "health=\(world.player?.health ?? 0) exited=\(world.exited)")

case "play":
    let o = Options.parse(rest)
    let wad = try loadWad(o)
    let game = Game(wad: wad)
    let world = try game.loadMap(o.map)
    let (w, h) = o.sizeParts()
    let renderer = Renderer(width: w, height: h, textures: game.textures)
    let display = TerminalDisplay()
    display.hideCursor()
    defer { display.showCursor() }
    let session = GameSession(game: game, renderer: renderer,
                              display: display, input: TerminalInput(),
                              audio: NullAudio())
    let host = ModHost(world: world)
    for m in ModRegistry.shared.mods { host.load(m) }
    loadMods(o.mods, into: host, modules: o.modules)
    host.mapLoaded(name: o.map)
    session.onTic = { _ in host.tick() }
    host.context.console.echo = { _ in } // keep terminal clean during play
    session.run()
    print("\nresult: health=\(world.player?.health ?? 0) exited=\(world.exited)")

case "modcheck":
    guard let path = rest.first else { usage() }
    let o = Options.parse(rest)
    let mod = try ScriptCompiler.compileAndLoad(path: path, modulesDir: o.modules)
    print("mod '\(mod.name)' v\(mod.version) compiled and loaded OK")

default:
    usage()
}
