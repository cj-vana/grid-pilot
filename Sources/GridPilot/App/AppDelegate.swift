import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ConfigStore!
    private var registry: ActionRegistry!
    private var engine: MappingEngine!
    private var midi: MIDIListener!
    private var menuBar: MenuBarController!
    private var learn: LearnController?
    private var callMode: CallModeController!
    private var callWatcher: CallWatcher!
    /// Last seen value per control, replayed after theme switches so the
    /// module can restore correct LED levels (it forgets positions).
    private var lastValues: [ControlKey: MIDIEvent] = [:]

    var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ConfigStore()
        let config = store.loadOrCreate()

        midi = MIDIListener(
            deviceName: config.midi.deviceName,
            onEvent: { [weak self] event in
                guard let self else { return }
                self.lastValues[ControlKey(type: event.type, number: event.number)] = event
                if let learn = self.learn {
                    learn.handle(event)
                    return
                }
                // Echo values back so a midirx LED handler in the Grid profile
                // can color LEDs from live positions (docs/grid-led-colors.md).
                if self.store.config.leds?.echo == true && !self.callMode.active {
                    self.midi.send(type: event.type, number: event.number, value: event.value, channel: event.channel)
                }
                if self.callMode.intercept(event) {
                    // consumed by ringing-call overlay
                } else if !self.isPaused {
                    self.engine.handle(event)
                }
            },
            onStateChange: { [weak self] connected in
                self?.menuBar.setConnected(connected)
                // Re-assert the LED theme after replug; the module forgets
                // runtime variables on power cycle.
                if connected { self?.sendLEDTheme() }
            }
        )
        registry = ActionRegistry(config: config, midiSend: { [weak self] cc, value, channel in
            self?.midi.send(cc: cc, value: value, channel: channel)
        })
        engine = MappingEngine(config: config, sink: registry)
        menuBar = MenuBarController(delegate: self, store: store)
        callMode = CallModeController(store: store, midiSend: { [weak self] type, number, value, channel in
            self?.midi.send(type: type, number: number, value: value, channel: channel)
        })
        callWatcher = CallWatcher(store: store) { [weak self] bundleID in
            self?.callMode.enter(bundleID: bundleID)
        }
        callWatcher.start()

        store.onChange = { [weak self] new in
            self?.engine.update(config: new)
            self?.registry.update(config: new)
            self?.menuBar.refresh()
        }
        store.startWatching()
        midi.start()

        Log.onError = { [weak self] message in
            DispatchQueue.main.async { self?.menuBar.showError(message) }
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleNotify(_:)),
            name: NSNotification.Name("io.gridpilot.notify"), object: nil
        )

        Log.info("GridPilot started")
        offerLearnModeIfFirstRun()
    }

    @objc private func handleNotify(_ notification: Notification) {
        let event = notification.object as? String ?? "event"
        Log.info("notify: \(event)")

        // "call:<bundleid>" enters ringing mode; "call-end" leaves it. Anything
        // else is a generic attention ping (Claude Code hooks land here).
        if event.hasPrefix("call:") {
            callMode.enter(bundleID: String(event.dropFirst("call:".count)))
            return
        }
        if event == "call-end" {
            callMode.exit()
            return
        }

        let config = store.config
        if config.notify.flashIcon {
            menuBar.flash()
        }
        for out in config.notify.midiOut {
            midi.send(cc: out.cc, value: out.value, channel: out.channel)
        }
    }

    func setLEDTheme(_ index: Int) {
        var config = store.config
        config.leds = LEDConfig(echo: config.leds?.echo ?? true, theme: index)
        try? store.apply(config, backup: false)
        sendLEDTheme()
    }

    func sendLEDTheme() {
        let theme = store.config.leds?.theme ?? 0
        midi.send(type: .cc, number: LEDConfig.themeSelectCC, value: theme, channel: LEDConfig.themeSelectChannel)
        // The module only knows positions it has heard; replay the latest so
        // LEDs light at real levels instead of wherever the palette left them.
        for event in lastValues.values {
            midi.send(type: event.type, number: event.number, value: event.value, channel: event.channel)
        }
    }

    func startLearnMode() {
        learn = LearnController(store: store) { [weak self] in
            self?.learn = nil
        }
        learn?.begin()
    }

    private func offerLearnModeIfFirstRun() {
        let marker = store.path.deletingLastPathComponent().appendingPathComponent(".learned")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? Data().write(to: marker)
        let alert = NSAlert()
        alert.messageText = "Welcome to GridPilot"
        alert.informativeText = "Let's capture your PBF4's actual CC numbers. You'll wiggle each control once — takes about 30 seconds."
        alert.addButton(withTitle: "Start Learn Mode")
        alert.addButton(withTitle: "Skip (use defaults)")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            startLearnMode()
        }
    }
}
