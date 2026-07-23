import AppKit
import ServiceManagement

final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private weak var appDelegate: AppDelegate?
    private let store: ConfigStore
    private var connected = false
    private var errorBadge = false
    private var customize: CustomizeWindowController?

    init(delegate: AppDelegate, store: ConfigStore) {
        self.appDelegate = delegate
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    func setConnected(_ value: Bool) {
        connected = value
        updateIcon()
    }

    func showError(_ message: String) {
        errorBadge = true
        updateIcon()
    }

    func refresh() {
        updateIcon()
    }

    func flash() {
        let original = statusItem.button?.image
        var count = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            count += 1
            self.statusItem.button?.image = count % 2 == 1
                ? NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "attention")
                : original
            if count >= 6 {
                timer.invalidate()
                self.statusItem.button?.image = original
            }
        }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func updateIcon() {
        let symbol: String
        if errorBadge {
            symbol = "slider.horizontal.2.square.badge.arrow.down"
        } else if !connected {
            symbol = "slider.horizontal.3"
        } else if appDelegate?.isPaused == true {
            symbol = "pause.circle"
        } else {
            symbol = "slider.horizontal.3"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "GridPilot")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !connected
    }

    // Rebuild every open so state (paused, provider, backups) is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        errorBadge = false
        updateIcon()

        let status = NSMenuItem(
            title: connected ? "Grid: connected" : "Grid: not found",
            action: nil, keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        for row in mappingRows() {
            let item = NSMenuItem(title: row, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: appDelegate?.isPaused == true ? "Resume" : "Pause",
            action: #selector(togglePause), keyEquivalent: "p"
        )
        pause.target = self
        menu.addItem(pause)

        menu.addItem(item("Customize with AI…", #selector(openCustomize), key: "k"))
        let revert = item("Revert Last Change", #selector(revertLast), key: "")
        revert.isEnabled = !store.backups().isEmpty
        menu.addItem(revert)
        menu.addItem(.separator())

        let provider = NSMenuItem(title: "AI Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        for name in ["codex", "claude"] {
            let entry = NSMenuItem(title: providerLabel(name), action: #selector(setProvider(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = name
            entry.state = store.config.ai.provider == name ? .on : .off
            providerMenu.addItem(entry)
        }
        providerMenu.addItem(.separator())
        for name in ["codex", "claude"] {
            let modelItem = NSMenuItem(title: "Set \(name) model…", action: #selector(promptModel(_:)), keyEquivalent: "")
            modelItem.target = self
            modelItem.representedObject = name
            providerMenu.addItem(modelItem)

            let effortItem = NSMenuItem(title: "\(name) effort", action: nil, keyEquivalent: "")
            let effortMenu = NSMenu()
            let current = name == "codex" ? store.config.ai.codex.effort : store.config.ai.claude.effort
            for effort in ["low", "medium", "high", "xhigh", "max"] {
                let entry = NSMenuItem(title: effort, action: #selector(setEffort(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = [name, effort]
                entry.state = current == effort ? .on : .off
                effortMenu.addItem(entry)
            }
            providerMenu.setSubmenu(effortMenu, for: effortItem)
            providerMenu.addItem(effortItem)
        }
        menu.setSubmenu(providerMenu, for: provider)
        menu.addItem(provider)

        let theme = NSMenuItem(title: "LED Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        let currentTheme = store.config.leds?.theme ?? 0
        for (index, name) in LEDConfig.themeNames.enumerated() {
            let entry = NSMenuItem(title: name, action: #selector(setLEDTheme(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = currentTheme == index ? .on : .off
            themeMenu.addItem(entry)
        }
        menu.setSubmenu(themeMenu, for: theme)
        menu.addItem(theme)

        let presets = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        let presetsMenu = NSMenu()
        let active = store.presetMatchingCurrent()
        for name in store.presets() {
            let entry = NSMenuItem(title: name, action: #selector(loadPreset(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = name
            entry.state = name == active ? .on : .off
            presetsMenu.addItem(entry)
        }
        if !presetsMenu.items.isEmpty { presetsMenu.addItem(.separator()) }
        let saveAs = NSMenuItem(title: "Save Current As…", action: #selector(savePresetAs), keyEquivalent: "")
        saveAs.target = self
        presetsMenu.addItem(saveAs)
        menu.setSubmenu(presetsMenu, for: presets)
        menu.addItem(presets)
        menu.addItem(.separator())

        menu.addItem(item("Learn Controls…", #selector(startLearn), key: ""))
        menu.addItem(item("Set Up Module LEDs", #selector(deployLEDs), key: ""))
        menu.addItem(item("Detect Modules → Update Config", #selector(detectModules), key: ""))
        menu.addItem(item("Open Config", #selector(openConfig), key: ""))
        menu.addItem(item("View Log", #selector(openLog), key: ""))

        let login = item("Launch at Login", #selector(toggleLogin), key: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit GridPilot", #selector(quit), key: "q"))
    }

    /// One glanceable line per control, straight from the live config.
    private func mappingRows() -> [String] {
        let config = store.config
        return Config.controlNames.compactMap { name in
            guard let mapping = config.mappings[name] else { return "\(name)   —" }
            if let action = mapping.action {
                return "\(name)   \(Self.label(for: action))"
            }
            var parts: [String] = []
            if let tap = mapping.tap { parts.append(Self.label(for: tap)) }
            if let hold = mapping.longPress { parts.append("hold: \(Self.label(for: hold))") }
            return "\(name)   \(parts.isEmpty ? "—" : parts.joined(separator: "  ·  "))"
        }
    }

    private static let friendlyNames: [String: String] = [
        "displayBrightness": "Display brightness",
        "micVolume": "Mic volume",
        "systemVolume": "System volume",
        "alertVolume": "Alert volume",
        "spotifyVolume": "Spotify volume",
        "nightShiftWarmth": "Night Shift warmth",
        "itermTabPicker": "iTerm tab picker",
        "outputDeviceDial": "Output device dial",
        "itermTransparency": "iTerm transparency",
        "contextEscape": "Interrupt (Esc to iTerm/ChatGPT)",
        "newClaudeSession": "New Claude session",
        "newCodexSession": "New Codex session",
        "screenshotRegion": "Screenshot region → clipboard",
        "screenshotFull": "Screenshot full → clipboard",
        "spotifyPlayPause": "Spotify play/pause",
        "spotifyNextTrack": "Spotify next track",
    ]

    static func label(for spec: ActionSpec) -> String {
        if let friendly = friendlyNames[spec.action] { return friendly }
        switch spec.action {
        case "shell":
            return "shell: \(snip(spec.string("command")))"
        case "applescript":
            return "AppleScript: \(snip(spec.string("source")))"
        case "keystroke":
            return "keystroke \(spec.number("keyCode").map { String(Int($0)) } ?? "?")"
        case "midiSend":
            return "MIDI out cc\(spec.number("cc").map { String(Int($0)) } ?? "?")"
        default:
            return spec.action
        }
    }

    private static func snip(_ text: String?) -> String {
        guard let text = text?.replacingOccurrences(of: "\n", with: " ") else { return "?" }
        return text.count > 32 ? String(text.prefix(32)) + "…" : text
    }

    private func providerLabel(_ name: String) -> String {
        let ai = store.config.ai
        let p = name == "codex" ? ai.codex : ai.claude
        return "\(name) — \(p.model) (\(p.effort))"
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePause() {
        appDelegate?.isPaused.toggle()
        updateIcon()
    }

    @objc private func openCustomize() {
        if customize == nil {
            customize = CustomizeWindowController(store: store) { [weak self] in
                self?.customize = nil
            }
        }
        customize?.show()
    }

    @objc private func revertLast() {
        do {
            try store.rollback()
        } catch {
            Log.error("revert failed: \(error.localizedDescription)")
        }
    }

    @objc private func setProvider(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var config = store.config
        config.ai.provider = name
        try? store.apply(config, backup: false)
    }

    @objc private func setLEDTheme(_ sender: NSMenuItem) {
        appDelegate?.setLEDTheme(sender.tag)
    }

    @objc private func loadPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        do {
            try store.loadPreset(named: name)
        } catch {
            Log.error("preset load failed: \(error.localizedDescription)")
        }
    }

    @objc private func savePresetAs() {
        let alert = NSAlert()
        alert.messageText = "Save current config as preset"
        alert.informativeText = "Shows up in the Presets menu; loading one swaps the whole mapping."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. Coding, Music, Streaming"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.savePreset(named: field.stringValue)
        } catch {
            Log.error("preset save failed: \(error.localizedDescription)")
        }
    }

    @objc private func promptModel(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        var config = store.config
        let current = provider == "codex" ? config.ai.codex.model : config.ai.claude.model
        let alert = NSAlert()
        alert.messageText = "Model for \(provider)"
        alert.informativeText = "Any model id the \(provider) CLI accepts."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let model = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        if provider == "codex" { config.ai.codex.model = model } else { config.ai.claude.model = model }
        try? store.apply(config, backup: false)
    }

    @objc private func setEffort(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        var config = store.config
        if pair[0] == "codex" { config.ai.codex.effort = pair[1] } else { config.ai.claude.effort = pair[1] }
        try? store.apply(config, backup: false)
    }

    @objc private func startLearn() {
        appDelegate?.startLearnMode()
    }

    @objc private func deployLEDs() {
        runSerialTask(title: "Set Up Module LEDs") { client in
            let report = LEDDeployer.deploy(client: client)
            DispatchQueue.main.async { self.appDelegate?.sendLEDTheme() }
            return (report.lines.joined(separator: "\n"), !report.failed)
        }
    }

    @objc private func detectModules() {
        runSerialTask(title: "Detect Modules") { client in
            let modules = client.modules
            guard !modules.isEmpty else { return ("no module heartbeats received", false) }
            var summary = modules.map { "\($0.name) at (\($0.x),\($0.y)) fw \($0.firmware.major).\($0.firmware.minor).\($0.firmware.patch)" }
            let (merged, added) = MapGenerator.merge(into: self.store.config, modules: modules)
            if added.isEmpty {
                summary.append("config already covers every module")
            } else {
                do {
                    try self.store.apply(merged, backup: true)
                    summary.append("added controls: \(added.joined(separator: ", "))")
                    summary.append("assign actions via Customize with AI")
                } catch {
                    return (error.localizedDescription, false)
                }
            }
            return (summary.joined(separator: "\n"), true)
        }
    }

    /// Serial ops run off-main; results land in a single alert. The port is
    /// exclusive, so failures usually mean Grid Editor is running.
    private func runSerialTask(title: String, work: @escaping (GridConfigClient) -> (String, Bool)) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: (String, Bool)
            if let client = GridConfigClient.openFirstAvailable() {
                Thread.sleep(forTimeInterval: 1.5)  // gather heartbeats
                outcome = work(client)
                client.stop()
            } else {
                outcome = ("could not open the Grid's serial port — quit Grid Editor if it's running, and check the USB cable", false)
            }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "\(title): \(outcome.1 ? "done" : "failed")"
                alert.informativeText = outcome.0
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(store.path)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.error("launch-at-login toggle failed (run from GridPilot.app, not swift run): \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
