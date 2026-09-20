import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import DoomEngine

// MARK: - Platform abstraction

/// A destination for rendered frames.
public protocol Display {
    func present(_ fb: Framebuffer)
}

/// A source of player input. `poll` returns the current button state.
public protocol InputSource {
    /// Called once before the loop starts (e.g. enter raw mode).
    func start()
    /// Called once when the loop ends.
    func stop()
    /// Current pressed buttons since last call.
    func poll() -> InputButtons
    /// Set when the user requested quit.
    var quitRequested: Bool { get }
}

/// Audio output. Sounds are procedural — no copyrighted samples.
public protocol AudioBackend {
    func play(_ sound: GameSound)
    func flush()
}

public enum GameSound: String, Sendable {
    case fire, pickup, door, hurt, monsterAlert, exit, step
}

// MARK: - Headless / test implementations

public final class NullDisplay: Display {
    public private(set) var presentedCount = 0
    public private(set) var lastChecksum: UInt64 = 0
    public init() {}
    public func present(_ fb: Framebuffer) {
        presentedCount += 1
        lastChecksum = fb.checksum()
    }
}

/// Writes each presented frame as a PPM file (frame000.ppm, ...).
public final class PPMDisplay: Display {
    let directory: URL
    let every: Int
    var frame = 0
    public init(directory: URL, every: Int = 35) {
        self.directory = directory
        self.every = every
    }
    public func present(_ fb: Framebuffer) {
        frame += 1
        guard frame % every == 0 else { return }
        let url = directory.appendingPathComponent(
            String(format: "frame%03d.ppm", frame / every))
        try? fb.ppmData().write(to: url)
    }
}

/// Queued-button input for tests and scripted demos.
public final class ScriptedInput: InputSource {
    private var queue: [(tics: Int, buttons: InputButtons)]
    private var ticsElapsed = 0
    public private(set) var quitRequested = false
    public init(script: [(tics: Int, buttons: InputButtons)]) {
        self.queue = script
    }
    public func start() {}
    public func stop() {}
    public func poll() -> InputButtons {
        ticsElapsed += 1
        var b: InputButtons = []
        while let head = queue.first, head.tics <= ticsElapsed {
            b.formUnion(head.buttons)
            queue.removeFirst()
        }
        return b
    }
}

public final class NullAudio: AudioBackend {
    public init() {}
    public func play(_ sound: GameSound) {}
    public func flush() {}
}

/// Renders procedural beep effects into a WAV file on flush.
/// Sounds are synthesized — no copyrighted samples are used or needed.
public final class WavAudio: AudioBackend {
    let url: URL
    var samples: [Int16] = []
    let sampleRate = 22050
    public init(url: URL) { self.url = url }

    public func play(_ sound: GameSound) {
        let freq: Double
        let dur: Double
        switch sound {
        case .fire: freq = 220; dur = 0.08
        case .pickup: freq = 880; dur = 0.05
        case .door: freq = 110; dur = 0.4
        case .hurt: freq = 160; dur = 0.12
        case .monsterAlert: freq = 90; dur = 0.25
        case .exit: freq = 660; dur = 0.3
        case .step: freq = 60; dur = 0.02
        }
        let n = Int(dur * Double(sampleRate))
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            let env = max(0.0, 1.0 - t / dur)
            let v = sin(2 * .pi * freq * t) * env * 0.3
            samples.append(Int16(v * 32767))
        }
    }

    public func flush() {
        var d = Data()
        let dataSize = UInt32(samples.count * 2)
        d.append(contentsOf: "RIFF".utf8)
        d.append(uint32le(36 + dataSize))
        d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8)
        d.append(uint32le(16))
        d.append(uint16le(1)) // PCM
        d.append(uint16le(1)) // mono
        d.append(uint32le(UInt32(sampleRate)))
        d.append(uint32le(UInt32(sampleRate * 2)))
        d.append(uint16le(2))
        d.append(uint16le(16))
        d.append(contentsOf: "data".utf8)
        d.append(uint32le(dataSize))
        for s in samples { d.append(uint16le(UInt16(bitPattern: s))) }
        try? d.write(to: url)
    }

    private func uint32le(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    private func uint16le(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8)])
    }
}

// MARK: - Terminal implementations (Linux/macOS)

/// Presents frames in a terminal using ANSI 24-bit color upper-half blocks.
public final class TerminalDisplay: Display {
    public init() {}

    public func present(_ fb: Framebuffer) {
        let (cols, rows) = terminalSize()
        let outW = min(cols, fb.width)
        let outH2 = min(rows * 2, fb.height) // two pixels per row via "▀"
        let xScale = Double(fb.width) / Double(outW)
        let yScale = Double(fb.height) / Double(outH2)
        var s = "\u{1B}[H" // cursor home
        for cy in 0..<(outH2 / 2) {
            var lastFG = (-1, -1, -1)
            var lastBG = (-1, -1, -1)
            for x in 0..<outW {
                let fx = min(fb.width - 1, Int(Double(x) * xScale))
                let yTop = min(fb.height - 1, Int(Double(cy * 2) * yScale))
                let yBot = min(fb.height - 1, Int(Double(cy * 2 + 1) * yScale))
                let ot = (yTop * fb.width + fx) * 3
                let ob = (yBot * fb.width + fx) * 3
                let fg = (Int(fb.pixels[ot]), Int(fb.pixels[ot + 1]), Int(fb.pixels[ot + 2]))
                let bg = (Int(fb.pixels[ob]), Int(fb.pixels[ob + 1]), Int(fb.pixels[ob + 2]))
                if fg != lastFG {
                    s += "\u{1B}[38;2;\(fg.0);\(fg.1);\(fg.2)m"
                    lastFG = fg
                }
                if bg != lastBG {
                    s += "\u{1B}[48;2;\(bg.0);\(bg.1);\(bg.2)m"
                    lastBG = bg
                }
                s += "▀"
            }
            s += "\u{1B}[0m\n"
        }
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    private func terminalSize() -> (Int, Int) {
        var ws = winsize()
        #if os(Linux)
        let req = UInt(TIOCGWINSZ)
        #else
        let req = UInt(TIOCGWINSZ)
        #endif
        if ioctl(STDOUT_FILENO, req, &ws) == 0, ws.ws_col > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (120, 40)
    }

    public func hideCursor() {
        FileHandle.standardOutput.write(Data("\u{1B}[?25l\u{1B}[2J".utf8))
    }
    public func showCursor() {
        FileHandle.standardOutput.write(Data("\u{1B}[?25h\u{1B}[0m\n".utf8))
    }
}

/// Raw-mode keyboard input from the terminal.
public final class TerminalInput: InputSource {
    private var oldTermios = termios()
    private var pressed: InputButtons = []
    public private(set) var quitRequested = false
    public init() {}

    public func start() {
        tcgetattr(STDIN_FILENO, &oldTermios)
        var raw = oldTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        #if os(Linux)
        raw.c_cc.6 = 0  // VMIN
        raw.c_cc.5 = 0  // VTIME
        #else
        raw.c_cc.16 = 0 // VMIN
        raw.c_cc.17 = 0 // VTIME
        #endif
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        // nonblocking
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)
    }

    public func stop() {
        tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        _ = fcntl(STDIN_FILENO, F_SETFL, flags & ~O_NONBLOCK)
    }

    public func poll() -> InputButtons {
        var buf = [UInt8](repeating: 0, count: 64)
        var newlyPressed: InputButtons = []
        var released: InputButtons = []
        while true {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 { break }
            for i in 0..<n {
                let c = buf[i]
                // arrow keys come as ESC [ A/B/C/D
                if c == 27, i + 2 < n, buf[i + 1] == UInt8(ascii: "[") {
                    switch buf[i + 2] {
                    case UInt8(ascii: "A"): newlyPressed.formUnion(.forward)
                    case UInt8(ascii: "B"): newlyPressed.formUnion(.back)
                    case UInt8(ascii: "C"): newlyPressed.formUnion(.turnRight)
                    case UInt8(ascii: "D"): newlyPressed.formUnion(.turnLeft)
                    default: break
                    }
                    continue
                }
                switch c {
                case UInt8(ascii: "w"): newlyPressed.formUnion(.forward)
                case UInt8(ascii: "s"): newlyPressed.formUnion(.back)
                case UInt8(ascii: "a"), UInt8(ascii: "h"): newlyPressed.formUnion(.turnLeft)
                case UInt8(ascii: "d"), UInt8(ascii: "l"): newlyPressed.formUnion(.turnRight)
                case UInt8(ascii: "z"): newlyPressed.formUnion(.strafeLeft)
                case UInt8(ascii: "c"): newlyPressed.formUnion(.strafeRight)
                case UInt8(ascii: " "), UInt8(ascii: "e"): newlyPressed.formUnion(.use)
                case UInt8(ascii: "f"): newlyPressed.formUnion(.fire)
                case UInt8(ascii: "r"): newlyPressed.formUnion(.run)
                case UInt8(ascii: "j"): newlyPressed.formUnion(.jump)
                case UInt8(ascii: "q"), 3: quitRequested = true
                default: break
                }
            }
        }
        // keys are momentary: movement keys "held" if pressed recently
        let heldMask: InputButtons = [.forward, .back, .turnLeft, .turnRight,
                                      .strafeLeft, .strafeRight, .run]
        let momentary: InputButtons = [.use, .fire, .jump]
        // decay held keys: keep them for ~2 polls so taps still move
        if !newlyPressed.intersection(heldMask).isEmpty {
            heldSince = 0
            heldButtons = newlyPressed.intersection(heldMask)
        } else {
            heldSince += 1
            if heldSince > 3 { heldButtons = [] }
        }
        pressed = heldButtons.union(newlyPressed.intersection(momentary))
        _ = released
        return pressed
    }
    private var heldButtons: InputButtons = []
    private var heldSince = 0
}
