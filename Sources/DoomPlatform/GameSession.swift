import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import DoomEngine

/// Ties World + Renderer + Display + Input + Audio into a runnable game loop.
public final class GameSession {
    public let game: Game
    public let renderer: Renderer
    public let display: Display
    public let input: InputSource
    public let audio: AudioBackend
    public let framebuffer: Framebuffer
    /// Optional per-tic hook (mods wire in here).
    public var onTic: (World) -> Void = { _ in }
    public var onFrame: (Framebuffer) -> Void = { _ in }

    public init(game: Game, renderer: Renderer, display: Display,
                input: InputSource, audio: AudioBackend) {
        self.game = game
        self.renderer = renderer
        self.display = display
        self.input = input
        self.audio = audio
        self.framebuffer = Framebuffer(width: renderer.width, height: renderer.height)
    }

    /// Run `tics` game tics headlessly, presenting the final frame.
    @discardableResult
    public func runTics(_ tics: Int, renderEveryTic: Bool = false) -> Framebuffer {
        guard let world = game.world, let pl = world.player else { return framebuffer }
        for _ in 0..<tics {
            pl.buttons = input.poll()
            world.tic()
            onTic(world)
            if renderEveryTic { renderFrame(world: world, viewpoint: pl.mobj) }
            if world.exited { break }
        }
        renderFrame(world: world, viewpoint: pl.mobj)
        return framebuffer
    }

    /// Interactive loop at 35 tics/second until quit or level exit.
    public func run() {
        guard let world = game.world, let pl = world.player else { return }
        input.start()
        defer { input.stop() }
        let ticNS = UInt64(1_000_000_000) / UInt64(Game.ticsPerSecond)
        var next = DispatchTime.now().uptimeNanoseconds
        while !input.quitRequested && !world.exited && pl.alive {
            pl.buttons = input.poll()
            world.tic()
            onTic(world)
            renderFrame(world: world, viewpoint: pl.mobj)
            next &+= ticNS
            let now = DispatchTime.now().uptimeNanoseconds
            if next > now {
                usleep(UInt32((next - now) / 1000))
            } else {
                next = now // fell behind: resync
            }
        }
        audio.flush()
    }

    private var fired = false
    private var usedDoor = false
    private func renderFrame(world: World, viewpoint: MapObject) {
        renderer.render(world: world, viewpoint: viewpoint, into: framebuffer)
        display.present(framebuffer)
        onFrame(framebuffer)
        // audio triggers from world events would go through DoomScripting;
        // basic ones handled here:
        if world.player?.attackCooldown == 11 { audio.play(.fire) }
        if world.exited && !fired { audio.play(.exit); fired = true }
        _ = usedDoor
    }
}
