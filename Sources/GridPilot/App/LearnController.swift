import AppKit

/// Steps through P1…B4, capturing each control's CC from live MIDI. Pots and
/// faders qualify after enough distinct values (a sweep); buttons after a
/// press+release pair.
final class LearnController {
    private let store: ConfigStore
    private let onDone: () -> Void
    private var panel: NSPanel!
    private var label: NSTextField!
    private var stepIndex = 0
    private var captured: [String: ControlDef] = [:]
    private var valuesSeen: [ControlKey: Set<Int>] = [:]
    private var sawHigh: Set<ControlKey> = []

    init(store: ConfigStore, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
    }

    private var currentControl: String? {
        stepIndex < Config.controlNames.count ? Config.controlNames[stepIndex] : nil
    }

    func begin() {
        let rect = NSRect(x: 0, y: 0, width: 420, height: 140)
        panel = NSPanel(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Learn Controls"
        panel.level = .floating
        panel.isReleasedWhenClosed = false

        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 20, y: 40, width: 380, height: 60)
        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        panel.contentView?.addSubview(label)

        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        prompt()
    }

    func handle(_ event: MIDIEvent) {
        guard let control = currentControl else { return }
        let key = ControlKey(type: event.type, number: event.number)
        // A control captured for an earlier step can't also be this one.
        guard !captured.values.contains(where: { $0.cc == key.number && $0.type == key.type }) else { return }

        let isButtonStep = control.hasPrefix("B")
        valuesSeen[key, default: []].insert(event.value)

        if isButtonStep {
            // Buttons are notes on Grid's default profile but CC on custom
            // ones; a press+release pair qualifies either way.
            if event.value >= 64 { sawHigh.insert(key) }
            if event.value < 64 && sawHigh.contains(key) && (valuesSeen[key]?.count ?? 0) <= 3 {
                capture(control: control, key: key, kind: .button)
            }
        } else if key.type == .cc && (valuesSeen[key]?.count ?? 0) >= 4 {
            capture(control: control, key: key, kind: .continuous)
        }
    }

    private func capture(control: String, key: ControlKey, kind: ControlKind) {
        captured[control] = ControlDef(cc: key.number, kind: kind, type: key.type)
        valuesSeen = [:]
        sawHigh = []
        stepIndex += 1
        if currentControl == nil {
            finish()
        } else {
            prompt()
        }
    }

    private func prompt() {
        guard let control = currentControl else { return }
        let (verb, place) = describe(control)
        label.stringValue = "\(stepIndex + 1) of \(Config.controlNames.count)\n\(verb) \(control) (\(place))"
    }

    private func describe(_ control: String) -> (String, String) {
        let position = ["1": "leftmost", "2": "second", "3": "third", "4": "rightmost"][String(control.dropFirst())] ?? ""
        switch control.first {
        case "P": return ("Twist pot", "\(position), top row")
        case "F": return ("Sweep fader", "\(position), middle row")
        default: return ("Press button", "\(position), bottom row")
        }
    }

    private func finish() {
        var config = store.config
        config.controls = captured
        do {
            try store.apply(config, backup: true)
            label.stringValue = "Done — all 12 controls captured."
        } catch {
            label.stringValue = "Failed to save: \(error.localizedDescription)"
            Log.error("learn mode save failed: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.panel.close()
            self?.onDone()
        }
    }
}
