import Foundation

/// Trailing-edge throttle: delivers immediately when idle, then at most one
/// value per interval, always ending on the latest value. Keeps AppleScript
/// targets from being flooded by a fader sweep.
final class Coalescer {
    private let intervalMs: UInt64
    private let now: () -> UInt64
    private let schedule: MappingEngine.Scheduler
    private var lastDelivery: UInt64 = 0
    private var pending: Float?
    private var timerArmed = false

    init(intervalMs: UInt64, now: @escaping () -> UInt64, schedule: @escaping MappingEngine.Scheduler) {
        self.intervalMs = intervalMs
        self.now = now
        self.schedule = schedule
    }

    func submit(value: Float, deliver: @escaping (Float) -> Void) {
        let t = now()
        if !timerArmed && t &- lastDelivery >= intervalMs {
            lastDelivery = t
            deliver(value)
            return
        }
        pending = value
        if !timerArmed {
            timerArmed = true
            schedule(Double(intervalMs) / 1000.0) { [weak self] in
                guard let self else { return }
                self.timerArmed = false
                self.lastDelivery = self.now()
                if let v = self.pending {
                    self.pending = nil
                    deliver(v)
                }
            }
        }
    }
}
