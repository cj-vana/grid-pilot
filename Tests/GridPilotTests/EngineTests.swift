import XCTest
@testable import GridPilot

/// Deterministic time: a fake clock plus a scheduler that queues blocks with
/// absolute fire times and runs them when the clock is advanced.
final class FakeTime {
    private(set) var nowMs: UInt64 = 1_000
    private var queue: [(fireAt: UInt64, block: () -> Void)] = []

    var now: () -> UInt64 { { self.nowMs } }
    var schedule: MappingEngine.Scheduler {
        { delay, block in
            self.queue.append((self.nowMs + UInt64(delay * 1000), block))
        }
    }

    func advance(ms: UInt64) {
        let target = nowMs + ms
        while let next = queue.filter({ $0.fireAt <= target }).min(by: { $0.fireAt < $1.fireAt }) {
            nowMs = next.fireAt
            queue.removeAll { $0.fireAt == next.fireAt && $0.fireAt <= target }
            next.block()
        }
        nowMs = target
    }
}

final class SpySink: ActionSink {
    var calls: [(action: String, value: Float?)] = []
    func run(_ spec: ActionSpec, value: Float?) {
        calls.append((spec.action, value))
    }
}

final class EngineTests: XCTestCase {
    var time: FakeTime!
    var sink: SpySink!
    var engine: MappingEngine!

    override func setUp() {
        super.setUp()
        time = FakeTime()
        sink = SpySink()
        engine = MappingEngine(config: .default, sink: sink, now: time.now, schedule: time.schedule)
    }

    /// Builds the event a given control would emit, using the default config's
    /// number and message type (buttons are notes, pots/faders are CCs).
    private func event(_ control: String, _ value: Int, channel: Int = 0) -> MIDIEvent {
        let def = Config.default.controls[control]!
        return MIDIEvent(type: def.type, number: def.cc, value: value, channel: channel)
    }

    func testContinuousControlRoutesNormalizedValue() {
        engine.handle(event("F2", 127))
        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertEqual(sink.calls[0].action, "systemVolume")
        XCTAssertEqual(sink.calls[0].value, 1.0)
    }

    func testCoalescerDropsIntermediateButDeliversLast() {
        for v in [10, 20, 30, 40, 50] {
            engine.handle(event("F2", v))
        }
        // First goes through immediately; the rest wait on the trailing timer.
        XCTAssertEqual(sink.calls.count, 1)
        XCTAssertEqual(sink.calls[0].value!, 10.0 / 127.0, accuracy: 0.001)
        time.advance(ms: 40)
        XCTAssertEqual(sink.calls.count, 2)
        XCTAssertEqual(sink.calls[1].value!, 50.0 / 127.0, accuracy: 0.001)
    }

    func testQuickPressIsTap() {
        engine.handle(event("B4", 127))
        XCTAssertEqual(sink.calls.count, 0)
        time.advance(ms: 100)
        engine.handle(event("B4", 0))
        XCTAssertEqual(sink.calls.map(\.action), ["spotifyPlayPause"])
    }

    func testNoteButtonIgnoresSameNumberCC() {
        // B1 is note 40 by default; a CC 40 must not fire it.
        let def = Config.default.controls["B1"]!
        engine.handle(MIDIEvent(type: .cc, number: def.cc, value: 127, channel: 0))
        engine.handle(MIDIEvent(type: .cc, number: def.cc, value: 0, channel: 0))
        XCTAssertEqual(sink.calls.count, 0)
    }

    func testHoldFiresLongPressAtThresholdAndSwallowsRelease() {
        engine.handle(event("B4", 127))
        time.advance(ms: 400)
        XCTAssertEqual(sink.calls.map(\.action), ["spotifyNextTrack"])
        engine.handle(event("B4", 0))
        XCTAssertEqual(sink.calls.count, 1, "release after long-press must not also tap")
    }

    func testTapOnlyButtonTreatsHoldAsTap() {
        engine.handle(event("B1", 127))  // contextEscape, no longPress mapping
        time.advance(ms: 500)
        engine.handle(event("B1", 0))
        XCTAssertEqual(sink.calls.map(\.action), ["contextEscape"])
    }

    func testUnmappedNumberIsIgnored() {
        engine.handle(MIDIEvent(type: .cc, number: 99, value: 64, channel: 0))
        XCTAssertEqual(sink.calls.count, 0)
    }

    func testChannelFilterRejectsOtherChannels() {
        var config = Config.default
        config.midi.channel = 2
        engine.update(config: config)
        engine.handle(event("F2", 64, channel: 0))
        XCTAssertEqual(sink.calls.count, 0)
        engine.handle(event("F2", 64, channel: 2))
        XCTAssertEqual(sink.calls.count, 1)
    }

    func testConfigUpdateRemapsControl() {
        var config = Config.default
        config.mappings["F2"] = Mapping(action: ActionSpec(action: "alertVolume"))
        engine.update(config: config)
        engine.handle(event("F2", 127))
        XCTAssertEqual(sink.calls.map(\.action), ["alertVolume"])
    }

    func testRepeatedPressEventsWhileDownDoNotDoubleFire() {
        engine.handle(event("B4", 127))
        engine.handle(event("B4", 127))
        time.advance(ms: 100)
        engine.handle(event("B4", 0))
        XCTAssertEqual(sink.calls.count, 1)
    }
}
