import XCTest
@testable import GridPilot

final class ZoneAndParseTests: XCTestCase {
    func testZoneIndexEdges() {
        XCTAssertEqual(zoneIndex(value: 0.0, zones: 4), 0)
        XCTAssertEqual(zoneIndex(value: 0.24, zones: 4), 0)
        XCTAssertEqual(zoneIndex(value: 0.26, zones: 4), 1)
        XCTAssertEqual(zoneIndex(value: 0.99, zones: 4), 3)
        XCTAssertEqual(zoneIndex(value: 1.0, zones: 4), 3)
        XCTAssertEqual(zoneIndex(value: 0.5, zones: 1), 0)
        XCTAssertEqual(zoneIndex(value: 0.5, zones: 0), 0)
        XCTAssertEqual(zoneIndex(value: -0.5, zones: 4), 0)
        XCTAssertEqual(zoneIndex(value: 1.5, zones: 4), 3)
    }

    func testParseEventExtractsControlChange() {
        // UMP MIDI 1.0: mt=2, group 0, status 0xB0 (CC ch0), cc 34, value 100
        let word: UInt32 = (2 << 28) | (0xB0 << 16) | (34 << 8) | 100
        XCTAssertEqual(parseEvent(word: word), MIDIEvent(type: .cc, number: 34, value: 100, channel: 0))
    }

    func testParseEventReadsChannel() {
        let word: UInt32 = (2 << 28) | (0xB5 << 16) | (7 << 8) | 127
        XCTAssertEqual(parseEvent(word: word)?.channel, 5)
    }

    func testParseEventHandlesNotes() {
        // Grid buttons: note on with velocity = press, note off = release.
        let noteOn: UInt32 = (2 << 28) | (0x90 << 16) | (40 << 8) | 127
        XCTAssertEqual(parseEvent(word: noteOn), MIDIEvent(type: .note, number: 40, value: 127, channel: 0))
        let noteOff: UInt32 = (2 << 28) | (0x80 << 16) | (40 << 8) | 64
        XCTAssertEqual(parseEvent(word: noteOff), MIDIEvent(type: .note, number: 40, value: 0, channel: 0))
    }

    func testParseEventRejectsSysexAndOtherStatuses() {
        let sysex: UInt32 = (3 << 28) | (0xB0 << 16) | (34 << 8) | 100
        XCTAssertNil(parseEvent(word: sysex))
        let aftertouch: UInt32 = (2 << 28) | (0xD0 << 16) | (34 << 8) | 100
        XCTAssertNil(parseEvent(word: aftertouch))
    }
}

final class TemplateTests: XCTestCase {
    func testSubstituteAllPlaceholders() {
        let result = substitute("v={{value}} p={{percent}} f={{float}}", value: 0.5)
        XCTAssertEqual(result, "v=64 p=50 f=0.50")
    }

    func testSubstituteExtremes() {
        XCTAssertEqual(substitute("{{value}}", value: 1.0), "127")
        XCTAssertEqual(substitute("{{percent}}", value: 0.0), "0")
    }

    func testSubstituteNilValueBlanksPlaceholders() {
        XCTAssertEqual(substitute("x{{value}}y", value: nil), "xy")
    }
}

final class RegistryTests: XCTestCase {
    var spy: SpyExecutors!
    var registry: ActionRegistry!
    var sentMIDI: [(Int, Int, Int)] = []

    final class SpyExecutors {
        var brightness: [Float] = []
        var shellCommands: [String] = []
        var scripts: [String] = []
        var keystrokes: [KeySpec] = []
        var selectedTabs: [Int] = []
        var selectedOutputs: [UInt32] = []
        var newTabs: [String] = []
        var frontmost: String? = "com.googlecode.iterm2"
        var tabCount = 4
        var devices: [(id: UInt32, name: String)] = [(10, "AirPods"), (20, "MacBook Pro Speakers")]

        func make() -> Executors {
            var e = Executors()
            e.displayBrightness = { self.brightness.append($0) }
            e.shell = { self.shellCommands.append($0) }
            e.applescript = { self.scripts.append($0) }
            e.keystroke = { self.keystrokes.append($0) }
            e.selectITermTab = { self.selectedTabs.append($0) }
            e.setDefaultOutput = { self.selectedOutputs.append($0) }
            e.newITermTab = { self.newTabs.append($0) }
            e.frontmostBundleID = { self.frontmost }
            e.itermTabCount = { self.tabCount }
            e.outputDevices = { self.devices }
            return e
        }
    }

    override func setUp() {
        super.setUp()
        spy = SpyExecutors()
        sentMIDI = []
        registry = ActionRegistry(
            config: .default,
            midiSend: { self.sentMIDI.append(($0, $1, $2)) },
            executors: spy.make()
        )
    }

    func testContinuousBuiltinRoutes() {
        registry.run(ActionSpec(action: "displayBrightness"), value: 0.7)
        XCTAssertEqual(spy.brightness, [0.7])
    }

    func testShellActionSubstitutesTemplate() {
        registry.run(ActionSpec(action: "shell", params: ["command": .string("say {{percent}}")]), value: 0.5)
        XCTAssertEqual(spy.shellCommands, ["say 50"])
    }

    func testContextEscapeSendsKeyInITerm() {
        spy.frontmost = "com.googlecode.iterm2"
        registry.run(ActionSpec(action: "contextEscape"), value: nil)
        XCTAssertEqual(spy.keystrokes.map(\.keyCode), [53])
    }

    func testContextEscapeNoOpsInUnknownApp() {
        spy.frontmost = "com.apple.finder"
        registry.run(ActionSpec(action: "contextEscape"), value: nil)
        XCTAssertTrue(spy.keystrokes.isEmpty)
    }

    func testNewSessionsUseYoloCommands() {
        registry.run(ActionSpec(action: "newClaudeSession"), value: nil)
        registry.run(ActionSpec(action: "newCodexSession"), value: nil)
        XCTAssertEqual(spy.newTabs, ["claude --dangerously-skip-permissions", "codex --yolo"])
    }

    func testTabPickerSelectsZoneOnceUntilItChanges() {
        spy.tabCount = 4
        registry.run(ActionSpec(action: "itermTabPicker"), value: 0.1)   // zone 0 → tab 1
        registry.run(ActionSpec(action: "itermTabPicker"), value: 0.15)  // still zone 0
        registry.run(ActionSpec(action: "itermTabPicker"), value: 0.9)   // zone 3 → tab 4
        XCTAssertEqual(spy.selectedTabs, [1, 4])
    }

    func testOutputDialHonorsConfiguredDeviceOrder() {
        let spec = ActionSpec(action: "outputDeviceDial", params: [
            "devices": .array([.string("MacBook Pro Speakers"), .string("AirPods")])
        ])
        registry.run(spec, value: 0.0)   // zone 0 → speakers (id 20)
        registry.run(spec, value: 1.0)   // zone 1 → AirPods (id 10)
        XCTAssertEqual(spy.selectedOutputs, [20, 10])
    }

    func testMIDISendAction() {
        registry.run(ActionSpec(action: "midiSend", params: ["cc": .number(60), "value": .number(127)]), value: nil)
        XCTAssertEqual(sentMIDI.count, 1)
        XCTAssertEqual(sentMIDI[0].0, 60)
        XCTAssertEqual(sentMIDI[0].1, 127)
        XCTAssertEqual(sentMIDI[0].2, 0)
    }
}
