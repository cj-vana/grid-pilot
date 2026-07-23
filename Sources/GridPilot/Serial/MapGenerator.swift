import Foundation

/// Generates config control entries for a discovered chain, using the
/// default dynamic layout: cc/note = 32 + x*16 + element, channel = y*4.
enum MapGenerator {
    /// Head PBF4 keeps the classic P/F/B names; every other module gets
    /// namespaced controls like "M1,0-E5". Unknown layouts are skipped.
    static func controls(for modules: [GridModule]) -> [String: ControlDef] {
        var result: [String: ControlDef] = [:]
        for module in modules {
            guard let elements = GridModuleCatalog.elements(hwcfg: module.hwcfg) else { continue }
            let base = 32 + module.x * 16
            let channel = ((module.y * 4) % 16 + 16) % 16
            let isHeadPBF4 = module.x == 0 && module.y == 0 && GridModuleCatalog.name(hwcfg: module.hwcfg) == "PBF4"

            var counters: [String: Int] = [:]
            for (index, element) in elements.enumerated() {
                let letter: String
                let kind: ControlKind
                let type: MIDIMessageType
                switch element {
                case .potmeter:
                    // PBF4 elements 4-7 are physically faders; letter only.
                    letter = isHeadPBF4 && index >= 4 ? "F" : "P"
                    kind = .continuous
                    type = .cc
                case .button:
                    letter = "B"
                    kind = .button
                    type = .note
                case .encoder, .endless:
                    letter = "E"
                    kind = .continuous
                    type = .cc
                case .touch:
                    continue
                }
                counters[letter, default: 0] += 1
                let name = isHeadPBF4
                    ? "\(letter)\(counters[letter]!)"
                    : "M\(module.x),\(module.y)-\(letter)\(counters[letter]!)"
                result[name] = ControlDef(cc: base + index, kind: kind, type: type, channel: channel)
            }
        }
        return result
    }

    /// Merges generated controls into a config: existing names win, new
    /// controls arrive unmapped (assign via AI or hand-edit).
    static func merge(into config: Config, modules: [GridModule]) -> (config: Config, added: [String]) {
        var updated = config
        var added: [String] = []
        for (name, def) in controls(for: modules).sorted(by: { $0.key < $1.key }) {
            if updated.controls[name] == nil,
               !updated.controls.values.contains(where: { $0.cc == def.cc && $0.type == def.type && $0.channel == def.channel }) {
                updated.controls[name] = def
                added.append(name)
            }
        }
        return (updated, added)
    }
}
