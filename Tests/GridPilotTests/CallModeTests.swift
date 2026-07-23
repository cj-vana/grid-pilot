import XCTest
@testable import GridPilot

final class CallModeTests: XCTestCase {
    func testRingingPhrasesMatch() {
        XCTAssertTrue(matchesRingingCall(title: "FaceTime", body: "Mom is calling you"))
        XCTAssertTrue(matchesRingingCall(title: "Incoming call", body: "JP"))
        XCTAssertTrue(matchesRingingCall(title: "Teams", body: "Video call from design sync"))
        XCTAssertTrue(matchesRingingCall(title: "Slack", body: "Sam started a huddle"))
    }

    func testNonRingingPhrasesDoNotMatch() {
        XCTAssertFalse(matchesRingingCall(title: "FaceTime", body: "Missed call from Mom"))
        XCTAssertFalse(matchesRingingCall(title: "Voicemail", body: "New voicemail"))
        XCTAssertFalse(matchesRingingCall(title: "Slack", body: "hey are you around?"))
        XCTAssertFalse(matchesRingingCall(title: "Teams", body: "Call ended: 32m"))
    }

    func testNotificationTextParsesBinaryPlist() throws {
        let payload: [String: Any] = ["req": ["titl": "FaceTime", "body": "Mom is calling you"]]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        let (title, body) = CallWatcher.notificationText(from: data)
        XCTAssertEqual(title, "FaceTime")
        XCTAssertEqual(body, "Mom is calling you")
    }

    func testCallConfigRoundTripsInsideConfig() throws {
        let config = Config.default
        XCTAssertNotNil(config.call)
        let decoded = try Config.decode(config.encodePretty())
        XCTAssertEqual(decoded.call, .standard)
    }

    func testConfigWithoutCallKeyStillDecodes() throws {
        var config = Config.default
        config.call = nil
        let decoded = try Config.decode(config.encodePretty())
        XCTAssertNil(decoded.call)
    }
}
