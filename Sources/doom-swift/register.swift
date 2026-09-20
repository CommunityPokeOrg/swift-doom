import DoomScripting

// Built-in example mods ship inside the binary. Runtime-compiled mods are
// loaded with --mod.
final class _Register {
    static let shared = _Register()
    private init() {
        ModRegistry.shared.register(StatsMod())
        ModRegistry.shared.register(GodMod())
        ModRegistry.shared.register(ImpRushMod())
    }
}

// Touch the registry at startup.
let _registerBuiltinMods: Void = { _ = _Register.shared }()
