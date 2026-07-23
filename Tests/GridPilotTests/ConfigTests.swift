import XCTest
@testable import GridPilot

final class ConfigTests: XCTestCase {
    func testDefaultConfigRoundTripsThroughJSON() throws {
        let original = Config.default
        let data = try original.encodePretty()
        let decoded = try Config.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testDefaultConfigIsValid() {
        XCTAssertEqual(ConfigValidator.validate(Config.default), [])
    }

    func testDefaultConfigCoversAllTwelveControls() {
        let config = Config.default
        XCTAssertEqual(Set(config.controls.keys), Set(Config.controlNames))
        XCTAssertEqual(Set(config.mappings.keys), Set(Config.controlNames))
    }

    func testValidatorRejectsUnknownAction() {
        var config = Config.default
        config.mappings["F3"] = Mapping(action: ActionSpec(action: "makeCoffee"))
        let problems = ConfigValidator.validate(config)
        XCTAssertTrue(problems.contains { $0.contains("unknown action \"makeCoffee\"") }, "\(problems)")
    }

    func testValidatorRejectsDuplicateCC() {
        var config = Config.default
        let p1cc = config.controls["P1"]!.cc
        config.controls["F1"]?.cc = p1cc
        let problems = ConfigValidator.validate(config)
        XCTAssertTrue(problems.contains { $0.contains("already used") }, "\(problems)")
    }

    func testValidatorRejectsButtonWithoutTapOrLongPress() {
        var config = Config.default
        config.mappings["B1"] = Mapping()
        let problems = ConfigValidator.validate(config)
        XCTAssertTrue(problems.contains { $0.contains("needs `tap`") }, "\(problems)")
    }

    func testValidatorRejectsContinuousActionOnButton() {
        var config = Config.default
        config.mappings["B1"] = Mapping(tap: ActionSpec(action: "systemVolume"))
        let problems = ConfigValidator.validate(config)
        XCTAssertTrue(problems.contains { $0.contains("needs a fader/pot") }, "\(problems)")
    }

    func testValidatorRejectsMissingRequiredParam() {
        var config = Config.default
        config.mappings["F3"] = Mapping(action: ActionSpec(action: "shell"))
        let problems = ConfigValidator.validate(config)
        XCTAssertTrue(problems.contains { $0.contains("requires param \"command\"") }, "\(problems)")
    }

    func testValidatorRejectsMappingForUndefinedControl() {
        var config = Config.default
        config.mappings["F9"] = Mapping(action: ActionSpec(action: "systemVolume"))
        let problems = ConfigValidator.validate(config)
        XCTAssertTrue(problems.contains { $0.contains("no such control") }, "\(problems)")
    }

    func testJSONValueDecodesMixedParams() throws {
        let json = """
        {"action": "shell", "params": {"command": "say hi", "loud": true, "level": 3, "list": ["a", 1]}}
        """
        let spec = try JSONDecoder().decode(ActionSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.string("command"), "say hi")
        XCTAssertEqual(spec.params?["loud"]?.boolValue, true)
        XCTAssertEqual(spec.params?["level"]?.numberValue, 3)
        XCTAssertEqual(spec.params?["list"]?.arrayValue?.count, 2)
    }
}
