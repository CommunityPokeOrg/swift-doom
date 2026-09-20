# swift-doom architecture

Three-layer SwiftPM package:

```
┌─────────────────────┐
│   DoomScripting     │  DoomMod protocol, ModContext, events, ScriptCompiler
├─────────────────────┤
│   DoomPlatform      │  Display / InputSource / AudioBackend, GameSession
├─────────────────────┤
│   DoomEngine        │  math, WAD, map/BSP, world sim, renderer, TestWad
└─────────────────────┘
```

The `doom-swift` executable composes all three.

## DoomEngine

### FixedPoint.swift
16.16 `Fixed` (like `fixed_t`), `Angle` (UInt32 BAM), sine/cosine tables,
`Vec2`, `lineSide` (64-bit cross product — the 16.16 version overflows at
map scale). Multiplication/division saturate instead of trapping; addition
and subtraction wrap (matching the original engine's semantics).

### Wad.swift
`WadFile` parses the 12-byte header + directory. Lump names are uppercased
and truncated to 8 chars on both write and lookup. `mapLumps(named:)` walks
the lumps following a map marker; `namespaceRange` resolves S_START/F_START
sprite/flat namespaces. `WadBuilder` writes WADs (used by TestWad and tests).

### Map.swift
Parses THINGS/LINEDEFS/SIDEDEFS/VERTEXES/SEGS/SSECTORS/NODES/SECTORS/REJECT/
BLOCKMAP. `blockLines` answers "linedefs near a rect" via the BLOCKMAP.
`sectorAt` walks the BSP to a leaf, then does exact point-in-sector ray
casting over the leaf's candidate sectors — necessary because generated
leaves can bundle several sectors (portal segs included), unlike a stock
Doom BSP whose leaves are convex single-sector regions.

### Graphics.swift
`IndexedImage` (palette-indexed, 255 transparent), `PatchDecoder` for the
column-post picture format, `TextureManager` resolving PNAMES +
TEXTURE1/2 composite textures, flats, and sprite frames (`spriteFrames`
keyed "IMPA" → "A1"…). Palette defaults to a generated RGB332 ramp.

### Game.swift
`World` holds things (`MapObject`), mutable sector state (`MapRuntime`),
thinkers, and the tic loop:

- movement via `move()` — blockmap-driven line sliding + thing collision,
  24-unit step-up, headroom checks
- combat — `hitscan` ray vs things and lines
- interaction — `activateUse` (switch/door specials), walk-over triggers,
  sector specials (damage floors, light strobes, exit pad)
- monster AI — chase/attack with line-of-sight checks
- events — `onEvent` callback emitting a `WorldEvent` stream for the
  scripting layer (kills, pickups, damage, door opens, level exit, …)

### Render.swift
Software renderer (column rasterizer, Doom-style):

1. BSP traversal front-to-back (`render` → `traverse` → `renderSubsector`).
2. Per-column ray↔seg solve gives exact depth + texcoord — no fisheye
   tables needed.
3. Solid walls write to a per-column depth buffer and close the clip
   window (`wtop`/`wbot`); portal segs emit upper/lower wall strips and
   record pending ceiling/floor spans that are flat-cast afterwards
   (`drawCeilSpan`/`drawFloorSpan`, sky gradient placeholder).
4. Sprites + masked mid textures are drawn far-to-near in `drawMasked`,
   clipped per-column by the wall z-buffer.
5. Light diminishing by sector light × depth; HUD overlays.

`Framebuffer` is an RGB byte buffer; `ppmData()` exports PPM for testing.

### TestWad.swift
Two things:

- `SimpleNodeBuilder` — a real BSP node builder: seg generation from
  linedefs (both sides for two-sided lines), splitter selection minimizing
  splits + imbalance, collinear segs routed by facing, degenerate/tiny
  splits become convex leaves. Output is standard SEGS/SSECTORS/NODES.
- `TestWad.build()` — a complete, original IWAD-format fixture generated in
  code: RGB332 PLAYPAL, brick/stone/door textures, three flats, procedural
  creature/item sprites, and a 7-sector map (two rooms, corridor, door,
  nukage pit, raised exit pad) with BLOCKMAP and things.

## DoomPlatform

Protocols `Display`, `InputSource`, `AudioBackend` isolate the engine from
the host:

| Backend | Purpose |
|---|---|
| `TerminalDisplay` | ANSI true-color half-block renderer (`▀`) |
| `TerminalInput` | raw termios key input |
| `PPMDisplay` | dumps every Nth frame to disk (demos/CI) |
| `ScriptedInput` | timed button scripts (demos/tests) |
| `WavAudio` | procedural beeps written to a WAV file |
| `NullDisplay`/`NullAudio` | headless |

`GameSession` runs the 35 Hz loop (`run()`) or a fixed headless run
(`runTics`), with `onTic`/`onFrame` hooks.

## DoomScripting

- `DoomMod` — mod protocol: `name`, `version`, `onLoad`, `onTick`,
  `onMapLoaded`, `onUnload` (all but `name` have defaults).
- `ModContext` — the mod's handle on everything: `world` (ModWorld proxy),
  `events` (EventBus), `console`, `commands`, `storage` (persisted dict).
- `ModWorld` — curated world access: queries (`things`, `thingPosition`,
  `sectorLight`, `lineOfSight`, `distance`, …) and mutations (`spawnThing`,
  `killThing`, `teleportThing`, `damageThing`, `setSectorFloorHeight`,
  `openDoor`, `giveAmmo`, `exitLevel`, `schedule`, …).
- `ModHost` — bridges `World.onEvent` → `context.events` and calls
  `onLoad`/`onTick`/`onMapLoaded`/`onUnload` for each loaded mod.
- `BuiltinMods` — in-process mods (`stats`, `god`, `imprush`) registered via
  `ModRegistry`.
- `ScriptCompiler` — runtime-compiles a `.swift` mod with `swiftc
  -emit-library` against the build's `Modules/` dir, `dlopen`s it, and wraps
  it in `LoadedMod`. See MODDING.md for the C-bridge ABI and why it exists.

## The game loop

`GameSession.run()` → 35 Hz: poll input → `world.tic()` (player think +
monster think + thinkers + scheduled mod tasks) → `renderer.render` →
`display.present` → `audio` events. Mods tick between the world tic and
the frame render.
