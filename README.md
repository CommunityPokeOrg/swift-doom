# swift-doom

A DOOM-engine-style game engine written entirely in Swift, with **runtime
Swift scripting for modding** — mod scripts are compiled with `swiftc` and
hot-loaded as dynamic libraries.

It renders a textured, BSP-partitioned world with a software renderer, runs a
35 Hz game loop with monsters, pickups, doors, sector specials, and a HUD —
and is 100% legally clean: it ships no DOOM assets. An original, procedurally
generated test WAD ("TESTWAD") is built in code, and the engine can also load
a real `doom.wad`/`doom2.wad` you own.

## Quick start

Requires a Swift toolchain (5.9+; built and tested with Swift 6.2 on Linux).

```sh
swift build          # builds doom-swift CLI + libraries
swift test           # 21 tests: WAD, map/BSP, game sim, renderer, scripting
```

Render a frame from the built-in test map (no assets needed):

```sh
.build/debug/doom-swift render --testwad --tics 60 --out frame.ppm
```

Headless scripted demo (walks, opens a door, fires — writes frames + audio):

```sh
.build/debug/doom-swift demo --tics 140
```

Interactive play in a terminal (ASCII renderer):

```sh
.build/debug/doom-swift play --testwad
# w/s move, a/d turn, z/c strafe, space/e use, f fire, r run, j jump, q quit
```

Write the test WAD to disk / inspect a WAD:

```sh
.build/debug/doom-swift mktwad test.wad
.build/debug/doom-swift wadinfo test.wad
.build/debug/doom-swift maps test.wad
```

## Modding (Swift scripts)

Write a `.swift` file conforming to `DoomMod`, then load it at runtime:

```sh
.build/debug/doom-swift play --testwad --mod Examples/lowgrav_mod.swift
.build/debug/doom-swift render --testwad --mod Examples/hello_mod.swift \
    --mod Examples/hordemode_mod.swift
.build/debug/doom-swift modcheck Examples/hello_mod.swift   # compile check
```

Minimal mod:

```swift
import DoomScripting

final class MyMod: DoomMod {
    let name = "my-mod"
    func onLoad(_ ctx: ModContext) { ctx.console.print("hello!") }
    func onTick(_ ctx: ModContext) { /* 35× per second */ }
}

@_cdecl("doommod_create")
public func doommod_create() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(MyMod()).toOpaque()
}
```

See [MODDING.md](MODDING.md) for the full API — world queries/mutations,
events, console commands, scheduled callbacks — and the bridging details.
Example mods live in [Examples/](Examples/).

## Layout

```
Sources/DoomEngine      engine core: fixed-point math, WAD, maps/BSP,
                        textures/sprites, game sim, software renderer,
                        test-WAD generator + BSP node builder
Sources/DoomPlatform    platform abstraction: Display/InputSource/
                        AudioBackend, terminal + PPM/WAV backends, game loop
Sources/DoomScripting   modding API: DoomMod, ModContext/ModWorld, events,
                        console, commands, ScriptCompiler (runtime swiftc),
                        builtin mods
Sources/doom-swift      command-line front end
Tests                   XCTest suites for all of the above
Examples                runtime-compilable mod scripts
ARCHITECTURE.md         engine design notes
MODDING.md              scripting/modding API reference
```

## Legal note

This project contains **no id Software assets or code**. Textures, flats,
sprites, the palette, and the test map are generated programmatically at
build time (`TestWad`). Real IWADs are loaded only if you supply your own
copy via `--wad`.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the engine design.

## License

MIT (see LICENSE).
