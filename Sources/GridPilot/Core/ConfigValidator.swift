import Foundation

enum ConfigValidator {
    /// Returns human-readable problems; empty means valid. Used on hand-edits,
    /// AI-proposed configs, and startup.
    static func validate(_ config: Config) -> [String] {
        var problems: [String] = []

        if config.version != 1 {
            problems.append("Unsupported config version \(config.version); expected 1.")
        }
        if config.longPressMs < 100 || config.longPressMs > 2000 {
            problems.append("longPressMs \(config.longPressMs) out of range 100...2000.")
        }

        var seenCCs: [Int: String] = [:]
        for (name, control) in config.controls.sorted(by: { $0.key < $1.key }) {
            if control.cc < 0 || control.cc > 127 {
                problems.append("Control \(name): CC \(control.cc) out of range 0...127.")
            }
            if let existing = seenCCs[control.cc] {
                problems.append("Control \(name): CC \(control.cc) already used by \(existing).")
            } else {
                seenCCs[control.cc] = name
            }
        }

        for (name, mapping) in config.mappings.sorted(by: { $0.key < $1.key }) {
            guard let control = config.controls[name] else {
                problems.append("Mapping \(name): no such control defined.")
                continue
            }
            switch control.kind {
            case .continuous:
                if mapping.action == nil {
                    problems.append("Mapping \(name): continuous control needs an `action`.")
                }
                if mapping.tap != nil || mapping.longPress != nil {
                    problems.append("Mapping \(name): tap/longPress only apply to buttons.")
                }
            case .button:
                if mapping.tap == nil && mapping.longPress == nil {
                    problems.append("Mapping \(name): button needs `tap` and/or `longPress`.")
                }
                if mapping.action != nil {
                    problems.append("Mapping \(name): `action` only applies to continuous controls; use tap/longPress.")
                }
            }
            for (slot, spec) in [("action", mapping.action), ("tap", mapping.tap), ("longPress", mapping.longPress)] {
                guard let spec else { continue }
                problems.append(contentsOf: check(spec, at: "\(name).\(slot)", kind: control.kind, slot: slot))
            }
        }

        if !["codex", "claude"].contains(config.ai.provider) {
            problems.append("ai.provider must be \"codex\" or \"claude\", got \"\(config.ai.provider)\".")
        }
        for entry in config.notify.midiOut {
            if entry.cc < 0 || entry.cc > 127 || entry.value < 0 || entry.value > 127 || entry.channel < 0 || entry.channel > 15 {
                problems.append("notify.midiOut entry cc=\(entry.cc) value=\(entry.value) channel=\(entry.channel) out of MIDI range.")
            }
        }
        return problems
    }

    private static func check(_ spec: ActionSpec, at path: String, kind: ControlKind, slot: String) -> [String] {
        guard let meta = Builtins.all[spec.action] else {
            return ["\(path): unknown action \"\(spec.action)\"."]
        }
        var problems: [String] = []
        switch meta.input {
        case .continuous where kind == .button:
            problems.append("\(path): action \"\(spec.action)\" needs a fader/pot, not a button.")
        case .trigger where kind == .continuous:
            problems.append("\(path): action \"\(spec.action)\" is a button action, not continuous.")
        default:
            break
        }
        for param in meta.requiredParams where spec.params?[param] == nil {
            problems.append("\(path): action \"\(spec.action)\" requires param \"\(param)\".")
        }
        return problems
    }
}
