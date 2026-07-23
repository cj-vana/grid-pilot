import Foundation

/// Arbitrary JSON for action params, so AI-added `shell`/`applescript` actions
/// can carry whatever they need without schema churn.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

struct ActionSpec: Codable, Equatable {
    var action: String
    var params: [String: JSONValue]?

    init(action: String, params: [String: JSONValue]? = nil) {
        self.action = action
        self.params = params
    }

    func string(_ key: String) -> String? { params?[key]?.stringValue }
    func number(_ key: String) -> Double? { params?[key]?.numberValue }
}

enum ControlKind: String, Codable {
    case continuous
    case button
}

struct ControlDef: Codable, Equatable {
    var cc: Int
    var kind: ControlKind
}

struct Mapping: Codable, Equatable {
    /// For continuous controls.
    var action: ActionSpec?
    /// For buttons.
    var tap: ActionSpec?
    var longPress: ActionSpec?

    init(action: ActionSpec? = nil, tap: ActionSpec? = nil, longPress: ActionSpec? = nil) {
        self.action = action
        self.tap = tap
        self.longPress = longPress
    }
}

struct MIDIConfig: Codable, Equatable {
    var deviceName: String
    /// nil = accept any channel.
    var channel: Int?
}

struct AIProviderConfig: Codable, Equatable {
    var model: String
    var effort: String
}

struct AIConfig: Codable, Equatable {
    /// "codex" or "claude"
    var provider: String
    var codex: AIProviderConfig
    var claude: AIProviderConfig
}

struct NotifyMIDI: Codable, Equatable {
    var cc: Int
    var value: Int
    var channel: Int
}

struct NotifyConfig: Codable, Equatable {
    var flashIcon: Bool
    /// CCs sent back to the Grid on `gridpilot notify` — wire these to LED
    /// reactions in your Grid Editor profile.
    var midiOut: [NotifyMIDI]
}

struct KeySpec: Codable, Equatable {
    /// macOS virtual key code (53 = Escape, 36 = Return).
    var keyCode: Int
    var modifiers: [String]?
}

struct Config: Codable, Equatable {
    var version: Int
    var midi: MIDIConfig
    var longPressMs: Int
    var controls: [String: ControlDef]
    var mappings: [String: Mapping]
    var ai: AIConfig
    var notify: NotifyConfig
    /// action name → frontmost bundle id → key to send. Apps not listed = no-op.
    var contextKeys: [String: [String: KeySpec]]

    static let controlNames = ["P1", "P2", "P3", "P4", "F1", "F2", "F3", "F4", "B1", "B2", "B3", "B4"]

    /// Approved PBF4 layout. CC numbers follow the Grid default profile guess
    /// (element index + 32); learn mode overwrites them with reality.
    static var `default`: Config {
        var controls: [String: ControlDef] = [:]
        for (i, name) in controlNames.enumerated() {
            controls[name] = ControlDef(cc: 32 + i, kind: name.hasPrefix("B") ? .button : .continuous)
        }
        return Config(
            version: 1,
            midi: MIDIConfig(deviceName: "Grid", channel: nil),
            longPressMs: 400,
            controls: controls,
            mappings: [
                "P1": Mapping(action: ActionSpec(action: "displayBrightness")),
                "P2": Mapping(action: ActionSpec(action: "micVolume")),
                "P3": Mapping(action: ActionSpec(action: "itermTabPicker")),
                "P4": Mapping(action: ActionSpec(action: "outputDeviceDial")),
                "F1": Mapping(action: ActionSpec(action: "spotifyVolume")),
                "F2": Mapping(action: ActionSpec(action: "systemVolume")),
                "F3": Mapping(action: ActionSpec(action: "alertVolume")),
                "F4": Mapping(action: ActionSpec(action: "nightShiftWarmth")),
                "B1": Mapping(tap: ActionSpec(action: "contextEscape")),
                "B2": Mapping(
                    tap: ActionSpec(action: "newClaudeSession"),
                    longPress: ActionSpec(action: "newCodexSession")
                ),
                "B3": Mapping(
                    tap: ActionSpec(action: "screenshotRegion"),
                    longPress: ActionSpec(action: "screenshotFull")
                ),
                "B4": Mapping(
                    tap: ActionSpec(action: "spotifyPlayPause"),
                    longPress: ActionSpec(action: "spotifyNextTrack")
                ),
            ],
            ai: AIConfig(
                provider: "codex",
                codex: AIProviderConfig(model: "gpt-5.6-sol", effort: "high"),
                claude: AIProviderConfig(model: "claude-opus-4-8", effort: "xhigh")
            ),
            notify: NotifyConfig(flashIcon: true, midiOut: []),
            contextKeys: [
                "contextEscape": [
                    "com.googlecode.iterm2": KeySpec(keyCode: 53),
                    "com.openai.chat": KeySpec(keyCode: 53),
                ]
            ]
        )
    }

    static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    func encodePretty() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
