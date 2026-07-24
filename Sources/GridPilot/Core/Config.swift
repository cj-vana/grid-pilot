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

enum MIDIMessageType: String, Codable {
    case cc
    case note
}

/// Grid encoders default to absolute (the module accumulates internally).
/// Profiles can opt into relative modes; these decode the two documented ones.
enum ControlEncoding: String, Codable {
    case absolute
    /// Sign-magnitude around 64: 65 = +1 step, 63 = -1 (endless_mode 1).
    case relative64
    /// Two's complement: 1 = +1, 127 = -1 (endless_mode 2, endless_max 127).
    case relative2c
}

struct ControlDef: Codable, Equatable {
    /// CC number or note number, depending on `type`. The JSON key stays "cc"
    /// for config compatibility.
    var cc: Int
    var kind: ControlKind
    var type: MIDIMessageType
    /// MIDI channel this control sends on; nil matches any channel. Chained
    /// Grid modules reuse the same CC numbers on different channels
    /// (channel = moduleY*4 + page), so multi-module setups need this set.
    var channel: Int?
    var encoding: ControlEncoding

    init(cc: Int, kind: ControlKind, type: MIDIMessageType = .cc, channel: Int? = nil, encoding: ControlEncoding = .absolute) {
        self.cc = cc
        self.kind = kind
        self.type = type
        self.channel = channel
        self.encoding = encoding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cc = try container.decode(Int.self, forKey: .cc)
        kind = try container.decode(ControlKind.self, forKey: .kind)
        // Configs written before note support have no `type`; they were all CC.
        type = try container.decodeIfPresent(MIDIMessageType.self, forKey: .type) ?? .cc
        channel = try container.decodeIfPresent(Int.self, forKey: .channel)
        encoding = try container.decodeIfPresent(ControlEncoding.self, forKey: .encoding) ?? .absolute
    }

    func matches(_ event: MIDIEvent) -> Bool {
        cc == event.number && type == event.type && (channel == nil || channel == event.channel)
    }
}

struct ControlKey: Hashable {
    var type: MIDIMessageType
    var number: Int
    /// nil acts as a wildcard slot; engine lookups try exact channel first.
    var channel: Int?
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

struct LEDConfig: Codable, Equatable {
    /// Echo every control event back to the Grid so a midirx handler in the
    /// module's profile can drive LED color/intensity from live values
    /// (see docs/grid-led-colors.md).
    var echo: Bool
    /// Palette index the Grid-side snippet uses (0 heat, 1 ocean, 2 synthwave,
    /// 3 matrix). Sent as CC 20 on channel 15 at connect and when changed.
    var theme: Int

    init(echo: Bool, theme: Int = 0) {
        self.echo = echo
        self.theme = theme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        echo = try container.decode(Bool.self, forKey: .echo)
        theme = try container.decodeIfPresent(Int.self, forKey: .theme) ?? 0
    }

    static let themeNames = ["Heat", "Ocean", "Synthwave", "Matrix", "Lava", "Mono"]
    static let themeSelectCC = 20
    static let themeSelectChannel = 15
}

struct KeySpec: Codable, Equatable {
    /// macOS virtual key code (53 = Escape, 36 = Return).
    var keyCode: Int
    var modifiers: [String]?
}

struct CallAppConfig: Codable, Equatable {
    var name: String
    /// Keystroke sent (after activating the app) when B1 answers. nil = just
    /// bring the app forward and let the user click.
    var answerKey: KeySpec?
}

struct CallConfig: Codable, Equatable {
    var enabled: Bool
    /// Call mode auto-expires after this long if nobody touches it.
    var ringTimeoutSec: Int
    /// Blink the button LEDs (via MIDI back to the Grid) while ringing.
    var flashLEDs: Bool
    /// bundle id → per-app call settings; only these apps trigger call mode.
    var apps: [String: CallAppConfig]

    static var standard: CallConfig {
        CallConfig(
            enabled: true,
            ringTimeoutSec: 45,
            flashLEDs: true,
            apps: [
                "com.apple.FaceTime": CallAppConfig(name: "FaceTime", answerKey: nil),
                "com.microsoft.teams2": CallAppConfig(name: "Microsoft Teams", answerKey: KeySpec(keyCode: 0, modifiers: ["cmd", "shift"])),
                "us.zoom.xos": CallAppConfig(name: "Zoom", answerKey: nil),
                "com.hnc.Discord": CallAppConfig(name: "Discord", answerKey: nil),
                "com.tinyspeck.slackmacgap": CallAppConfig(name: "Slack", answerKey: nil),
            ]
        )
    }
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
    /// Incoming-call mode; optional so configs predating the feature decode.
    var call: CallConfig?
    /// LED feedback; optional so configs predating the feature decode.
    var leds: LEDConfig?

    static let controlNames = ["P1", "P2", "P3", "P4", "F1", "F2", "F3", "F4", "B1", "B2", "B3", "B4"]

    /// Approved PBF4 layout. Grid's default profile sends CC 32+element for
    /// pots/faders and Note 32+element for buttons (elements run 0-11 top to
    /// bottom); learn mode overwrites with whatever the profile really emits.
    static var `default`: Config {
        var controls: [String: ControlDef] = [:]
        for (i, name) in controlNames.enumerated() {
            let isButton = name.hasPrefix("B")
            controls[name] = ControlDef(cc: 32 + i, kind: isButton ? .button : .continuous, type: isButton ? .note : .cc)
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
                "P4": Mapping(action: ActionSpec(action: "itermTransparency")),
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
                claude: AIProviderConfig(model: "claude-opus-5", effort: "xhigh")
            ),
            notify: NotifyConfig(flashIcon: true, midiOut: []),
            contextKeys: [
                "contextEscape": [
                    "com.googlecode.iterm2": KeySpec(keyCode: 53),
                    "com.openai.chat": KeySpec(keyCode: 53),
                ]
            ],
            call: .standard,
            leds: LEDConfig(echo: true)
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
