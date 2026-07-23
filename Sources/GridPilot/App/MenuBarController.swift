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
        menu.setSubmenu(providerMenu, for: provider)
        menu.addItem(provider)
        menu.addItem(.separator())

        menu.addItem(item("Learn Controls…", #selector(startLearn), key: ""))
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

    @objc private func startLearn() {
        appDelegate?.startLearnMode()
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
