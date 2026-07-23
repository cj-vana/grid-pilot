import Foundation

protocol ActionSink: AnyObject {
    /// value is 0...1 for continuous controls, nil for button fires.
    func run(_ spec: ActionSpec, value: Float?)
}

/// Routes raw CC events to actions: normalizes continuous values through a
/// per-control coalescer, feeds buttons through tap/long-press detection.
final class MappingEngine {
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private var config: Config
    private weak var sink: ActionSink?
    private let now: () -> UInt64  // milliseconds
    private let schedule: Scheduler
    private var coalescers: [ControlKey: Coalescer] = [:]
    private var gestures: [ControlKey: ButtonGesture] = [:]
    private var byKey: [ControlKey: (name: String, control: ControlDef)] = [:]

    init(
        config: Config,
        sink: ActionSink,
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
        schedule: @escaping Scheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.config = config
        self.sink = sink
        self.now = now
        self.schedule = schedule
        rebuild()
    }

    func update(config: Config) {
        self.config = config
        rebuild()
    }

    func handle(_ event: MIDIEvent) {
        if let expected = config.midi.channel, expected != event.channel { return }
        let key = ControlKey(type: event.type, number: event.number)
        guard let (name, control) = byKey[key], let mapping = config.mappings[name] else { return }

        switch control.kind {
        case .continuous:
            guard let spec = mapping.action else { return }
            let normalized = Float(min(max(event.value, 0), 127)) / 127.0
            coalescer(for: key).submit(value: normalized) { [weak self] v in
                self?.sink?.run(spec, value: v)
            }
        case .button:
            // Note buttons: on = press, off/vel-0 = release. CC buttons: ≥64 press.
            gesture(for: key, mapping: mapping).handle(pressed: event.value >= 64)
        }
    }

    private func rebuild() {
        byKey = [:]
        for (name, control) in config.controls {
            byKey[ControlKey(type: control.type, number: control.cc)] = (name, control)
        }
        // Drop stale per-control state so remapped controls start clean.
        coalescers = [:]
        gestures = [:]
    }

    private func coalescer(for key: ControlKey) -> Coalescer {
        if let existing = coalescers[key] { return existing }
        let created = Coalescer(intervalMs: 33, now: now, schedule: schedule)
        coalescers[key] = created
        return created
    }

    private func gesture(for key: ControlKey, mapping: Mapping) -> ButtonGesture {
        if let existing = gestures[key] { return existing }
        let created = ButtonGesture(
            longPressMs: config.longPressMs,
            schedule: schedule,
            onTap: { [weak self] in
                if let spec = mapping.tap { self?.sink?.run(spec, value: nil) }
            },
            onLongPress: { [weak self] in
                // A button with only a tap action treats a long hold as a tap,
                // so single-action buttons never feel dead.
                if let spec = mapping.longPress ?? mapping.tap { self?.sink?.run(spec, value: nil) }
            }
        )
        gestures[key] = created
        return created
    }
}
