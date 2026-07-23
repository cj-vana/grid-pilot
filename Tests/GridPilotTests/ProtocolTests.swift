import XCTest
@testable import GridPilot

/// Byte-exact vectors from the protocol spec (docs/grid-serial-protocol.md),
/// themselves verified against intechstudio/grid-protocol's encoder.
final class ProtocolTests: XCTestCase {
    private func ascii(_ data: Data) -> String {
        String(bytes: data, encoding: .ascii)!
    }

    func testHostHeartbeatMatchesSpecVector() {
        let packet = GridProtocol.hostHeartbeat(id: 1, session: 0)
        let expected = "\u{01}\u{0F}00280100000000000000\u{17}\u{02}010effff010505\u{03}\u{04}42\u{0A}"
        XCTAssertEqual(ascii(packet), expected)
        XCTAssertEqual(packet.count, 43)
    }

    func testConfigWriteMatchesSpecVector() {
        var params: [UInt8] = []
        params += GridProtocol.hexParam(1, width: 2)
        params += GridProtocol.hexParam(5, width: 2)
        params += GridProtocol.hexParam(5, width: 2)
        params += GridProtocol.hexParam(0, width: 2)
        params += GridProtocol.hexParam(12, width: 2)
        params += GridProtocol.hexParam(0, width: 2)
        let script = "--[[@cb]]glp(1,100)"
        params += GridProtocol.hexParam(script.utf8.count, width: 4)
        params += Array(script.utf8)
        let section = GridProtocol.classSection(code: 0x060, instruction: 0xE, params: params)
        let packet = GridProtocol.packet(id: 2, session: 0, to: GridProtocol.Address(dx: 0, dy: 0), classSection: section)
        let expected = "\u{01}\u{0F}0041020000007f7f0000\u{17}\u{02}060e010505000c000013--[[@cb]]glp(1,100)\u{03}\u{04}0f\u{0A}"
        XCTAssertEqual(ascii(packet), expected)
        XCTAssertEqual(packet.count, 68)
    }

    func testPageStoreMatchesSpecVector() {
        let section = GridProtocol.classSection(code: 0x061, instruction: 0xE, params: [])
        let packet = GridProtocol.packet(id: 3, session: 0, to: .global, classSection: section)
        let expected = "\u{01}\u{0F}001e0300000000000000\u{17}\u{02}061e\u{03}\u{04}19\u{0A}"
        XCTAssertEqual(ascii(packet), expected)
    }

    func testFrameSplitterFindsBoundaries() {
        var splitter = GridProtocol.FrameSplitter()
        let one = GridProtocol.hostHeartbeat(id: 1, session: 0)
        let two = GridProtocol.hostHeartbeat(id: 2, session: 0)
        // Deliver in awkward chunks.
        var frames: [[UInt8]] = []
        let combined = one + two
        let cut = 10
        frames += splitter.ingest(combined.prefix(cut))
        frames += splitter.ingest(combined.dropFirst(cut))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].first, GridProtocol.SOH)
        XCTAssertNotNil(GridProtocol.validateFrame(frames[0]))
        XCTAssertNotNil(GridProtocol.validateFrame(frames[1]))
    }

    func testValidateFrameRejectsCorruption() {
        var splitter = GridProtocol.FrameSplitter()
        var bytes = [UInt8](GridProtocol.hostHeartbeat(id: 1, session: 0))
        bytes[8] ^= 0x01  // flip a header bit
        let frames = splitter.ingest(Data(bytes))
        XCTAssertEqual(frames.count, 1)
        XCTAssertNil(GridProtocol.validateFrame(frames[0]))
    }

    func testHeartbeatDecodeRoundTrip() {
        // Simulated module heartbeat: PBF4 RevH (hwcfg 67) at (1,0), fw 1.5.5.
        var params: [UInt8] = []
        params += GridProtocol.hexParam(0, width: 2)     // TYPE
        params += GridProtocol.hexParam(67, width: 2)    // HWCFG
        params += GridProtocol.hexParam(1, width: 2)
        params += GridProtocol.hexParam(5, width: 2)
        params += GridProtocol.hexParam(5, width: 2)
        let section = GridProtocol.classSection(code: 0x010, instruction: 0xE, params: params)
        var frame = [UInt8](GridProtocol.packet(id: 9, session: 3, to: .global, classSection: section))
        // Stamp module coords into SX/SY ((1,0) → 0x80, 0x7f).
        frame.replaceSubrange(10..<14, with: Array("807f".utf8))
        // Re-checksum after the edit.
        let body = Array(frame[0..<(frame.count - 3)])
        frame.replaceSubrange((frame.count - 3)..<(frame.count - 1), with: GridProtocol.checksum(body))

        var splitter = GridProtocol.FrameSplitter()
        let frames = splitter.ingest(Data(frame))
        XCTAssertEqual(frames.count, 1)
        guard let valid = GridProtocol.validateFrame(frames[0]),
              let heartbeat = GridProtocol.decodeHeartbeat(valid) else {
            return XCTFail("heartbeat did not decode")
        }
        XCTAssertEqual(heartbeat.x, 1)
        XCTAssertEqual(heartbeat.y, 0)
        XCTAssertEqual(heartbeat.hwcfg, 67)
        XCTAssertEqual(heartbeat.major, 1)
        XCTAssertEqual(heartbeat.patch, 5)
        XCTAssertEqual(GridModuleCatalog.name(hwcfg: 67), "PBF4")
    }
}

final class DeployerTests: XCTestCase {
    func testPBF4HeadScriptRangesAndBudget() throws {
        let module = GridModule(x: 0, y: 0, hwcfg: 65, firmware: (1, 5, 5), lastSeen: Date())
        let script = try XCTUnwrap(LEDDeployer.systemSetupScript(for: module))
        XCTAssertTrue(script.hasPrefix("--[[@cb]]"))
        XCTAssertTrue(script.contains("p>=32 and p<=39"), "pots/faders CC 32-39")
        XCTAssertTrue(script.contains("p>=40 and p<=43"), "buttons notes 40-43")
        XCTAssertTrue(script.contains("for n=0,11 do"))
        XCTAssertTrue(script.contains("c//4==0 and m==176"))
        XCTAssertLessThanOrEqual(script.utf8.count, 908)
    }

    func testChainedModuleGetsOffsetsAndChannel() throws {
        // EN16 above-right of head: x=1 → CC base 48, y=-1 → channel 12.
        let module = GridModule(x: 1, y: -1, hwcfg: 193, firmware: (1, 5, 5), lastSeen: Date())
        let script = try XCTUnwrap(LEDDeployer.systemSetupScript(for: module))
        XCTAssertTrue(script.contains("c//4==3 and m==176 and p>=48 and p<=63"), script)
        XCTAssertTrue(script.contains("for n=0,15 do"))
        XCTAssertFalse(script.contains("m==144"), "EN16 has no buttons, no note branch")
    }

    func testBU16IsAllNotes() throws {
        let module = GridModule(x: 0, y: 0, hwcfg: 128, firmware: (1, 5, 5), lastSeen: Date())
        let script = try XCTUnwrap(LEDDeployer.systemSetupScript(for: module))
        XCTAssertFalse(script.contains("m==176 and p>=32"), "no CC element branch")
        XCTAssertTrue(script.contains("p>=32 and p<=47"), script)
    }

    func testUnknownModuleReturnsNil() {
        let module = GridModule(x: 0, y: 0, hwcfg: 161, firmware: (1, 5, 5), lastSeen: Date())
        XCTAssertNil(LEDDeployer.systemSetupScript(for: module))
    }
}

final class MapGeneratorTests: XCTestCase {
    func testHeadPBF4KeepsClassicNames() {
        let head = GridModule(x: 0, y: 0, hwcfg: 65, firmware: (1, 5, 5), lastSeen: Date())
        let controls = MapGenerator.controls(for: [head])
        XCTAssertEqual(controls["P1"], ControlDef(cc: 32, kind: .continuous, type: .cc, channel: 0))
        XCTAssertEqual(controls["F1"], ControlDef(cc: 36, kind: .continuous, type: .cc, channel: 0))
        XCTAssertEqual(controls["B4"], ControlDef(cc: 43, kind: .button, type: .note, channel: 0))
        XCTAssertEqual(controls.count, 12)
    }

    func testChainedEN16GetsNamespacedControls() {
        let head = GridModule(x: 0, y: 0, hwcfg: 65, firmware: (1, 5, 5), lastSeen: Date())
        let en16 = GridModule(x: 1, y: -1, hwcfg: 193, firmware: (1, 5, 5), lastSeen: Date())
        let controls = MapGenerator.controls(for: [head, en16])
        XCTAssertEqual(controls["M1,-1-E1"], ControlDef(cc: 48, kind: .continuous, type: .cc, channel: 12))
        XCTAssertEqual(controls["M1,-1-E16"], ControlDef(cc: 63, kind: .continuous, type: .cc, channel: 12))
        XCTAssertEqual(controls.count, 12 + 16)
    }

    func testMergePreservesExistingAndReportsAdded() {
        let head = GridModule(x: 0, y: 0, hwcfg: 65, firmware: (1, 5, 5), lastSeen: Date())
        let bu16 = GridModule(x: 1, y: 0, hwcfg: 128, firmware: (1, 5, 5), lastSeen: Date())
        let (merged, added) = MapGenerator.merge(into: .default, modules: [head, bu16])
        // Head PBF4 controls already exist (learned) — only BU16 arrives.
        XCTAssertEqual(added.count, 16)
        XCTAssertTrue(added.allSatisfy { $0.hasPrefix("M1,0-B") })
        XCTAssertEqual(merged.controls["P1"], Config.default.controls["P1"], "existing entries untouched")
        XCTAssertEqual(ConfigValidator.validate(merged), [])
    }
}
