import Foundation

enum ActionInput {
    /// Wants a 0...1 value (fader/pot).
    case continuous
    /// Fires on tap/long-press.
    case trigger
    /// Usable from either control type (shell/applescript/keystroke/midiSend).
    case either
}

struct BuiltinMeta {
    var input: ActionInput
    var requiredParams: [String]
    var doc: String
}

/// The catalog drives validation, the AI schema doc, and registry dispatch.
/// Add an entry here and a case in ActionRegistry.run to grow the vocabulary.
enum Builtins {
    static let all: [String: BuiltinMeta] = [
        "displayBrightness": BuiltinMeta(input: .continuous, requiredParams: [], doc: "Main display brightness (private DisplayServices API)."),
        "micVolume": BuiltinMeta(input: .continuous, requiredParams: [], doc: "Default input device volume; 0 mutes."),
        "systemVolume": BuiltinMeta(input: .continuous, requiredParams: [], doc: "Default output device volume."),
        "alertVolume": BuiltinMeta(input: .continuous, requiredParams: [], doc: "macOS alert/notification volume."),
        "spotifyVolume": BuiltinMeta(input: .continuous, requiredParams: [], doc: "Spotify app volume, independent of system volume."),
        "nightShiftWarmth": BuiltinMeta(input: .continuous, requiredParams: [], doc: "Night Shift strength (private CoreBrightness API); 0 disables."),
        "itermTabPicker": BuiltinMeta(input: .continuous, requiredParams: [], doc: "Knob zones select the focused iTerm tab."),
        "outputDeviceDial": BuiltinMeta(input: .continuous, requiredParams: [], doc: "Knob zones switch the default audio output device. Optional param `devices`: ordered name list."),
        "contextEscape": BuiltinMeta(input: .trigger, requiredParams: [], doc: "Send the key configured in contextKeys for the frontmost app; no-op elsewhere."),
        "newClaudeSession": BuiltinMeta(input: .trigger, requiredParams: [], doc: "New iTerm tab running `claude --dangerously-skip-permissions`. Optional param `command` overrides."),
        "newCodexSession": BuiltinMeta(input: .trigger, requiredParams: [], doc: "New iTerm tab running `codex --yolo`. Optional param `command` overrides."),
        "screenshotRegion": BuiltinMeta(input: .trigger, requiredParams: [], doc: "Interactive region screenshot to clipboard."),
        "screenshotFull": BuiltinMeta(input: .trigger, requiredParams: [], doc: "Full-screen screenshot to clipboard."),
        "spotifyPlayPause": BuiltinMeta(input: .trigger, requiredParams: [], doc: "Toggle Spotify playback."),
        "spotifyNextTrack": BuiltinMeta(input: .trigger, requiredParams: [], doc: "Skip to next Spotify track."),
        "shell": BuiltinMeta(input: .either, requiredParams: ["command"], doc: "Run a zsh command. Templates: {{value}} 0-127, {{percent}} 0-100, {{float}} 0-1."),
        "applescript": BuiltinMeta(input: .either, requiredParams: ["source"], doc: "Run AppleScript source. Same templates as shell."),
        "keystroke": BuiltinMeta(input: .trigger, requiredParams: ["keyCode"], doc: "Send a keystroke. Params: keyCode (int), modifiers (array of cmd/shift/option/control)."),
        "midiSend": BuiltinMeta(input: .either, requiredParams: ["cc", "value"], doc: "Send a CC back to the Grid (LED feedback). Params: cc, value, channel (default 0)."),
    ]
}
