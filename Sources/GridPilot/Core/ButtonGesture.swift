import Foundation

/// Press/release → tap or long-press. Long-press fires the moment the
/// threshold elapses (snappier than firing on release); the release is then
/// swallowed.
final class ButtonGesture {
    private let longPressMs: Int
    private let schedule: MappingEngine.Scheduler
    private let onTap: () -> Void
    private let onLongPress: () -> Void
    private var pressGeneration = 0
    private var isDown = false
    private var longPressFired = false

    init(
        longPressMs: Int,
        schedule: @escaping MappingEngine.Scheduler,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void
    ) {
        self.longPressMs = longPressMs
        self.schedule = schedule
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    func handle(pressed: Bool) {
        if pressed {
            guard !isDown else { return }
            isDown = true
            longPressFired = false
            pressGeneration += 1
            let generation = pressGeneration
            schedule(Double(longPressMs) / 1000.0) { [weak self] in
                guard let self, self.isDown, self.pressGeneration == generation else { return }
                self.longPressFired = true
                self.onLongPress()
            }
        } else {
            guard isDown else { return }
            isDown = false
            if !longPressFired {
                onTap()
            }
        }
    }
}
