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
    private var coalescers: [Int: Coalescer] = [:]
    private var gestures: [Int: ButtonGesture] = [:]
    private var byCC: [Int: (name: String, control: ControlDef)] = [:]

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

    func handle(cc: Int, value: Int, channel: Int) {
        if let expected = config.midi.channel, expected != channel { return }
        guard let (name, control) = byCC[cc], let mapping = config.mappings[name] else { return }

        switch control.kind {
        case .continuous:
            guard let spec = mapping.action else { return }
            let normalized = Float(min(max(value, 0), 127)) / 127.0
            coalescer(for: cc).submit(value: normalized) { [weak self] v in
                self?.sink?.run(spec, value: v)
            }
        case .button:
            gesture(for: cc, mapping: mapping).handle(pressed: value >= 64)
        }
    }

    private func rebuild() {
        byCC = [:]
        for (name, control) in config.controls {
            byCC[control.cc] = (name, control)
        }
        // Drop stale per-CC state so remapped controls start clean.
        coalescers = [:]
        gestures = [:]
    }

    private func coalescer(for cc: Int) -> Coalescer {
        if let existing = coalescers[cc] { return existing }
        let created = Coalescer(intervalMs: 33, now: now, schedule: schedule)
        coalescers[cc] = created
        return created
    }

    private func gesture(for cc: Int, mapping: Mapping) -> ButtonGesture {
        if let existing = gestures[cc] { return existing }
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
        gestures[cc] = created
        return created
    }
}
