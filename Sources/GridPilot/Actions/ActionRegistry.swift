import Foundation

/// Side-effect closures, injectable so registry routing is testable without
/// touching real audio devices, AppleScript, or the keyboard.
struct Executors {
    var displayBrightness: (Float) -> Void = { DisplayBrightness.set($0) }
    var micVolume: (Float) -> Void = { Audio.setInputVolume($0) }
    var systemVolume: (Float) -> Void = { Audio.setOutputVolume($0) }
    var alertVolume: (Float) -> Void = { Scripts.setAlertVolume($0) }
    var spotifyVolume: (Float) -> Void = { Scripts.spotifyIfRunning("set sound volume to \(Int(($0 * 100).rounded()))") }
    var nightShift: (Float) -> Void = { NightShift.setStrength($0) }
    var spotifyCommand: (String) -> Void = { Scripts.spotify($0) }
    var newITermTab: (String) -> Void = { Scripts.newITermTab(command: $0) }
    var selectITermTab: (Int) -> Void = { Scripts.selectITermTab(index: $0) }
    var itermTabCount: () -> Int = { Scripts.itermTabCount() }
    var itermTransparency: (Float) -> Void = {
        Scripts.runAppleScript("tell application \"iTerm2\" to tell current session of current window to set transparency to \(String(format: "%.2f", $0 * 0.85))")
    }
    var outputDevices: () -> [(id: UInt32, name: String)] = { Audio.outputDevices() }
    var setDefaultOutput: (UInt32) -> Void = { Audio.setDefaultOutput($0) }
    var keystroke: (KeySpec) -> Void = { Keystroke.send($0) }
    var shell: (String) -> Void = { Scripts.runShell($0) }
    var applescript: (String) -> Void = { Scripts.runAppleScript($0) }
    var screenshot: (Bool) -> Void = { Scripts.screenshot(interactive: $0) }
    var frontmostBundleID: () -> String? = { ContextRouter.frontmostBundleID() }
}

final class ActionRegistry: ActionSink {
    private var config: Config
    private let executors: Executors
    private let midiSend: (Int, Int, Int) -> Void

    // Zone hysteresis: only act when the computed zone actually changes.
    private var lastTabZone: Int?
    private var lastOutputZone: Int?
    private var cachedTabCount: (count: Int, at: Date)?

    init(config: Config, midiSend: @escaping (Int, Int, Int) -> Void, executors: Executors = Executors()) {
        self.config = config
        self.midiSend = midiSend
        self.executors = executors
    }

    func update(config: Config) {
        self.config = config
        lastTabZone = nil
        lastOutputZone = nil
    }

    func run(_ spec: ActionSpec, value: Float?) {
        switch spec.action {
        case "displayBrightness": if let v = value { executors.displayBrightness(v) }
        case "micVolume": if let v = value { executors.micVolume(v) }
        case "systemVolume": if let v = value { executors.systemVolume(v) }
        case "alertVolume": if let v = value { executors.alertVolume(v) }
        case "spotifyVolume": if let v = value { executors.spotifyVolume(v) }
        case "nightShiftWarmth": if let v = value { executors.nightShift(v) }
        case "itermTabPicker": if let v = value { pickITermTab(v) }
        case "outputDeviceDial": if let v = value { pickOutputDevice(v, spec: spec) }
        case "itermTransparency": if let v = value { executors.itermTransparency(v) }
        case "contextEscape": contextKeystroke(action: spec.action)
        case "newClaudeSession":
            executors.newITermTab(spec.string("command") ?? "claude --dangerously-skip-permissions")
        case "newCodexSession":
            executors.newITermTab(spec.string("command") ?? "codex --yolo")
        case "screenshotRegion": executors.screenshot(true)
        case "screenshotFull": executors.screenshot(false)
        case "spotifyPlayPause": executors.spotifyCommand("playpause")
        case "spotifyNextTrack": executors.spotifyCommand("next track")
        case "shell":
            if let command = spec.string("command") { executors.shell(substitute(command, value: value)) }
        case "applescript":
            if let source = spec.string("source") { executors.applescript(substitute(source, value: value)) }
        case "keystroke":
            if let code = spec.number("keyCode") {
                let modifiers = spec.params?["modifiers"]?.arrayValue?.compactMap(\.stringValue)
                executors.keystroke(KeySpec(keyCode: Int(code), modifiers: modifiers))
            }
        case "midiSend":
            if let cc = spec.number("cc"), let v = spec.number("value") {
                midiSend(Int(cc), Int(v), Int(spec.number("channel") ?? 0))
            }
        default:
            Log.error("unknown action \"\(spec.action)\" — config validation should have caught this")
        }
    }

    private func contextKeystroke(action: String) {
        let bundleID = executors.frontmostBundleID()
        guard let key = ContextRouter.key(for: action, config: config, bundleID: bundleID) else { return }
        executors.keystroke(key)
    }

    private func pickITermTab(_ value: Float) {
        let count = tabCount()
        guard count > 0 else { return }
        let zone = zoneIndex(value: value, zones: count)
        guard zone != lastTabZone else { return }
        lastTabZone = zone
        executors.selectITermTab(zone + 1)  // AppleScript tabs are 1-based
    }

    private func pickOutputDevice(_ value: Float, spec: ActionSpec) {
        var devices = executors.outputDevices()
        if let wanted = spec.params?["devices"]?.arrayValue?.compactMap(\.stringValue), !wanted.isEmpty {
            // Honor the configured order; drop names that aren't present.
            devices = wanted.compactMap { name in devices.first { $0.name == name } }
        }
        guard !devices.isEmpty else { return }
        let zone = zoneIndex(value: value, zones: devices.count)
        guard zone != lastOutputZone else { return }
        lastOutputZone = zone
        executors.setDefaultOutput(devices[zone].id)
    }

    private func tabCount() -> Int {
        // AppleScript round-trips are slow; cache for a second.
        if let cached = cachedTabCount, Date().timeIntervalSince(cached.at) < 1.0 {
            return cached.count
        }
        let count = executors.itermTabCount()
        cachedTabCount = (count, Date())
        return count
    }
}
