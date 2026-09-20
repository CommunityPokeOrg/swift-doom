# Modding swift-doom with Swift

swift-doom mods are ordinary `.swift` source files compiled at runtime into
dynamic libraries and `dlopen`'d into the engine. A mod gets a `ModContext`
with a safe, curated API — no engine internals needed.

## Writing a mod

```swift
import DoomScripting

final class MyMod: DoomMod {
    let name = "my-mod"          // required
    let version = "1.0"          // optional (default "0.1")

    func onLoad(_ ctx: ModContext) {   ctx.console.print("[my-mod] loaded") }
    func onMapLoaded(_ ctx: ModContext, mapName: String) { }
    func onTick(_ ctx: ModContext) {   // 35× per second
    }
    func onUnload(_ ctx: ModContext) { }
}

// required entry point: return an opaque retained pointer to your mod
@_cdecl("doommod_create")
public func doommod_create() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(MyMod()).toOpaque()
}
```

`Unmanaged.passRetained` keeps your object alive for the mod's lifetime; the
engine releases it on unload.

## Loading

```sh
doom-swift play   --testwad --mod my_mod.swift
doom-swift render --testwad --mod a.swift --mod b.swift   # multiple mods
doom-swift modcheck my_mod.swift        # compile-check without running
```

The compiler needs the build's module dir; it searches
`.build/{debug,release}/Modules` (and env var `SWIFT_DOOM_MODULES`, flag
`--modules`).

## ModContext API

### `ctx.world` — ModWorld

Queries:
`player` position/health/armor/ammo · `things(ofType:)` ·
`thingPosition(_:)` · `thingHealth(_:)` · `sectorFloorHeight(_:)` ·
`sectorLight(_:)` · `sectorCount` · `lineOfSight(a:b)` · `distance` ·
`ticCount`

Mutations:
`spawnThing(type:x:y:angleDegrees:)` · `killThing` · `removeThing` ·
`teleportThing` · `damageThing` · `setSectorLight` ·
`setSectorFloorHeight` · `setSectorFloorFlat` · `openDoor` ·
`giveHealth` / `giveAmmo` / `giveArmor` · `hurtPlayer` · `thrustPlayer` ·
`jumpPlayer` · `exitLevel` · `schedule(tics:block:)` (delayed callbacks)

### `ctx.events` — EventBus

Subscribe to engine events:

```swift
ctx.events.on(.thingKilled) { e in ctx.console.print("kill!") }
ctx.events.subscribe(matching: { $0.kind == .pickup }) { _ in }
```

Kinds: `thingKilled`, `thingDamaged`, `thingSpawned`, `pickup`,
`doorOpened`, `lineActivated`, `playerFired`, `playerHurt`, `exit`,
`mapLoaded`, `tic` …

### `ctx.commands` — console commands

```swift
ctx.commands.register("impstorm") { ctx, _ in
    ctx.world.spawnThing(type: 3001, x: 200, y: 256)
}
ctx.commands.run("impstorm")   // dispatch
```

### `ctx.console`, `ctx.storage`

`console.print`/`warn` route to the host's output; `storage` is a
`[String: Any]` scratch dict that persists for the session.

## Useful doomed numbers

| num  | thing         |
|------|---------------|
| 1    | player start  |
| 3001 | imp           |
| 3002 | demon         |
| 2035 | barrel        |
| 2011/2012/2014 | stimpack / medikit / health bonus |
| 2015/2018      | armor bonus / green armor       |
| 2007 | ammo clip     |

## Examples

- `Examples/hello_mod.swift` — minimal lifecycle + events
- `Examples/lowgrav_mod.swift` — per-tic world mutation (low gravity jump)
- `Examples/hordemode_mod.swift` — spawning, scheduling, HUD events

## How the runtime bridge works

The host may embed `DoomScripting` statically (test binaries do), while
your mod dylib links `libDoomScripting.so` — two distinct `DoomMod`
descriptors, so the host cannot cast your object to the protocol.

Instead, `ScriptCompiler` appends an auto-generated bridge file to your
mod's compile job. The bridge exports C entry points
(`doommod_name`, `doommod_on_tick`, …) that cast and dispatch **inside the
dylib** where its own `DoomMod` conformance is valid; `ModContext` is
passed through as an opaque pointer and reconstructed with
`Unmanaged<ModContext>.fromOpaque` (class method dispatch works across the
boundary because it's driven by the instance's `isa`). The host wraps
everything in `LoadedMod`, a normal `DoomMod`.

Consequences:

- You only ever write the `doommod_create` factory — the bridge is
  invisible.
- Don't `as?` engine types across the boundary yourself; go through
  `ModContext` methods.

## Safety notes

- Mods run in-process with full privileges — only load mods you trust.
- Mod scripts compile with the host Swift toolchain; mismatched ABI Swift
  versions can fail to load.
- Errors (compile failures, missing `doommod_create`) surface as
  `ScriptCompiler.Error` — `modcheck` reports them verbatim.
