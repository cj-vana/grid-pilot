import XCTest
@testable import GridPilot

final class StoreTests: XCTestCase {
    var dir: URL!
    var store: ConfigStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gridpilot-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigStore(path: dir.appendingPathComponent("config.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testLoadOrCreateWritesDefaultConfig() throws {
        let config = store.loadOrCreate()
        XCTAssertEqual(config, .default)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path.path))
        let onDisk = try Config.decode(Data(contentsOf: store.path))
        XCTAssertEqual(onDisk, .default)
    }

    func testApplyBacksUpAndRollbackRestores() throws {
        store.loadOrCreate()
        var changed = Config.default
        changed.longPressMs = 600
        try store.apply(changed, backup: true)
        XCTAssertEqual(store.backups().count, 1)
        XCTAssertEqual(store.config.longPressMs, 600)

        let restored = try store.rollback()
        XCTAssertEqual(restored.longPressMs, 400)
        XCTAssertEqual(store.backups().count, 0, "rollback consumes the backup")
        let onDisk = try Config.decode(Data(contentsOf: store.path))
        XCTAssertEqual(onDisk.longPressMs, 400)
    }

    func testApplyRejectsInvalidConfig() {
        store.loadOrCreate()
        var bad = Config.default
        bad.mappings["F1"] = Mapping(action: ActionSpec(action: "nonsense"))
        XCTAssertThrowsError(try store.apply(bad, backup: true))
        XCTAssertEqual(store.config, .default, "rejected config must not stick")
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try Data("not json{{".utf8).write(to: store.path)
        XCTAssertEqual(store.loadOrCreate(), .default)
    }

    func testRollbackWithoutBackupsThrows() {
        store.loadOrCreate()
        XCTAssertThrowsError(try store.rollback())
    }
}

final class AITests: XCTestCase {
    var dir: URL!
    var store: ConfigStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gridpilot-ai-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigStore(path: dir.appendingPathComponent("config.json"))
        store.loadOrCreate()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func customizer(reply: String) -> AICustomizer {
        AICustomizer(store: store, runner: { _, _ in .success(reply) }, compileAppleScript: false)
    }

    private func validReplyJSON(mutate: (inout Config) -> Void) -> String {
        var config = Config.default
        mutate(&config)
        let json = String(data: try! config.encodePretty(), encoding: .utf8)!
        return json
    }

    func testFencedReplyIsParsedAndDiffed() {
        let reply = "Sure, here you go:\n```json\n\(validReplyJSON { $0.mappings["F3"] = Mapping(action: ActionSpec(action: "spotifyVolume")) })\n```\nDone."
        let expectation = expectation(description: "ai")
        customizer(reply: reply).customize(request: "put spotify volume on F3") { result in
            switch result {
            case .success(let ai):
                XCTAssertTrue(ai.summary.contains { $0.contains("F3") }, "\(ai.summary)")
            case .failure(let message):
                XCTFail(message)
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testUnfencedJSONStillParses() {
        let reply = validReplyJSON { $0.longPressMs = 500 }
        let expectation = expectation(description: "ai")
        customizer(reply: reply).customize(request: "bump long press") { result in
            if case .failure(let message) = result { XCTFail(message) }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testGarbageReplyFails() {
        let expectation = expectation(description: "ai")
        customizer(reply: "I can't help with that").customize(request: "x") { result in
            if case .success = result { XCTFail("garbage must not become a config") }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testInvalidProposedConfigIsRejected() {
        let reply = validReplyJSON { $0.mappings["B1"] = Mapping(tap: ActionSpec(action: "systemVolume")) }
        let expectation = expectation(description: "ai")
        customizer(reply: reply).customize(request: "x") { result in
            switch result {
            case .success: XCTFail("validator must reject continuous action on button")
            case .failure(let message): XCTAssertTrue(message.contains("invalid config"), message)
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testRunnerFailurePropagates() {
        let failing = AICustomizer(store: store, runner: { _, _ in .failure("codex not found") }, compileAppleScript: false)
        let expectation = expectation(description: "ai")
        failing.customize(request: "x") { result in
            if case .failure(let message) = result {
                XCTAssertTrue(message.contains("codex not found"))
            } else {
                XCTFail()
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testClaudeEnvelopeParsing() {
        var config = Config.default
        config.longPressMs = 700
        let inner = String(data: try! config.encodePretty(), encoding: .utf8)!
        let fenced = "```json\n\(inner)\n```"
        let envelope: [String: Any] = ["result": fenced, "session_id": "x"]
        let stdout = String(data: try! JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!

        var claudeConfig = Config.default
        claudeConfig.ai.provider = "claude"
        try! store.apply(claudeConfig, backup: false)

        let expectation = expectation(description: "ai")
        customizer(reply: stdout).customize(request: "x") { result in
            switch result {
            case .success(let ai): XCTAssertEqual(ai.newConfig.longPressMs, 700)
            case .failure(let message): XCTFail(message)
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 5)
    }

    func testArgvForBothProviders() {
        let out = URL(fileURLWithPath: "/tmp/x.txt")
        let codexArgv = AICustomizer.argv(for: Config.default.ai, outFile: out)
        XCTAssertEqual(codexArgv.first, "codex")
        XCTAssertTrue(codexArgv.contains("gpt-5.6-sol"))
        XCTAssertTrue(codexArgv.contains("model_reasoning_effort=\"high\""))

        var claude = Config.default.ai
        claude.provider = "claude"
        let claudeArgv = AICustomizer.argv(for: claude, outFile: out)
        XCTAssertEqual(claudeArgv.first, "claude")
        XCTAssertTrue(claudeArgv.contains("claude-opus-5"))
        XCTAssertTrue(claudeArgv.contains("xhigh"))
    }

    func testDiffSummaryNamesChangedControls() {
        var new = Config.default
        new.mappings["B4"] = Mapping(tap: ActionSpec(action: "spotifyNextTrack"))
        let summary = AICustomizer.diffSummary(old: .default, new: new)
        XCTAssertTrue(summary.contains { $0.hasPrefix("B4:") }, "\(summary)")
    }

    func testExtractJSONPrefersLastFence() {
        let raw = "```json\n{\"a\": 1}\n```\ntext\n```json\n{\"b\": 2}\n```"
        XCTAssertEqual(AICustomizer.extractJSON(raw), "{\"b\": 2}")
    }

    func testExtractJSONHandlesBracesInsideStrings() {
        let raw = "prefix {\"key\": \"va}lue\", \"n\": {\"x\": 1}} suffix"
        XCTAssertEqual(AICustomizer.extractJSON(raw), "{\"key\": \"va}lue\", \"n\": {\"x\": 1}}")
    }
}

final class PresetTests: XCTestCase {
    var dir: URL!
    var store: ConfigStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gridpilot-preset-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigStore(path: dir.appendingPathComponent("config.json"))
        store.loadOrCreate()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testSaveListLoadRoundTrip() throws {
        try store.savePreset(named: "Coding")
        var changed = Config.default
        changed.longPressMs = 900
        try store.apply(changed, backup: false)
        try store.savePreset(named: "Music")

        XCTAssertEqual(store.presets(), ["Coding", "Music"])
        XCTAssertEqual(store.presetMatchingCurrent(), "Music")

        try store.loadPreset(named: "Coding")
        XCTAssertEqual(store.config.longPressMs, 400)
        XCTAssertEqual(store.presetMatchingCurrent(), "Coding")
        XCTAssertFalse(store.backups().isEmpty, "loading a preset backs up the previous config")
    }

    func testEmptyPresetNameRejected() {
        XCTAssertThrowsError(try store.savePreset(named: "  "))
    }
}

final class ChannelRoutingTests: XCTestCase {
    func testSameNumberDifferentChannelRoutesToDistinctControls() {
        var config = Config.default
        // Simulate a chained module: same CC 32, channel 12, mapped elsewhere.
        config.controls["P1"]?.channel = 0
        config.controls["M2.P1"] = ControlDef(cc: 32, kind: .continuous, type: .cc, channel: 12)
        config.mappings["M2.P1"] = Mapping(action: ActionSpec(action: "alertVolume"))
        let time = FakeTime()
        let sink = SpySink()
        let engine = MappingEngine(config: config, sink: sink, now: time.now, schedule: time.schedule)

        engine.handle(MIDIEvent(type: .cc, number: 32, value: 127, channel: 0))
        engine.handle(MIDIEvent(type: .cc, number: 32, value: 127, channel: 12))
        XCTAssertEqual(sink.calls.map(\.action), ["displayBrightness", "alertVolume"])
    }

    func testWildcardChannelStillMatchesAnything() {
        let time = FakeTime()
        let sink = SpySink()
        let engine = MappingEngine(config: .default, sink: sink, now: time.now, schedule: time.schedule)
        engine.handle(MIDIEvent(type: .cc, number: 36, value: 127, channel: 7))
        XCTAssertEqual(sink.calls.map(\.action), ["spotifyVolume"])
    }
}
