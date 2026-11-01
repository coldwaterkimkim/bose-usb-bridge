import XCTest
@testable import BoseUSBBridge

final class RoutingPolicyTests: XCTestCase {
    let available: Set<String> = ["bose", "monitor", "builtin"]
    func testRestoreOwnedOutput() {
        let s = RoutingSession(previousUID: "monitor", targetUID: "bose")
        XCTAssertEqual(RoutingPolicy.restoreUID(session: s, currentUID: "bose", availableUIDs: available), "monitor")
    }
    func testNeverUndoManualOutputWhileConnected() {
        let s = RoutingSession(previousUID: "monitor", targetUID: "bose")
        XCTAssertNil(RoutingPolicy.restoreUID(session: s, currentUID: "builtin", availableUIDs: available))
    }
    func testDisconnectRestoresAfterOSFallback() {
        let s = RoutingSession(previousUID: "monitor", targetUID: "bose")
        XCTAssertEqual(RoutingPolicy.restoreUID(session: s, currentUID: "builtin", availableUIDs: ["monitor", "builtin"]), "monitor")
    }
    func testRecordedManualChoiceSurvivesUnplug() {
        let s = RoutingSession(previousUID: "monitor", targetUID: "bose", restoreAllowed: false)
        XCTAssertNil(RoutingPolicy.restoreUID(session: s, currentUID: "builtin", availableUIDs: ["monitor", "builtin"]))
    }
    func testMissingPreviousDeviceIsNotRecreated() {
        let s = RoutingSession(previousUID: "monitor", targetUID: "bose")
        XCTAssertNil(RoutingPolicy.restoreUID(session: s, currentUID: "builtin", availableUIDs: ["builtin"]))
    }
    func testInvalidAndRememberedVolumes() {
        XCTAssertEqual(RoutingPolicy.initialVolume(remembered: nil), 0.3)
        XCTAssertEqual(RoutingPolicy.initialVolume(remembered: .nan), 0.3)
        XCTAssertEqual(RoutingPolicy.initialVolume(remembered: 1.2), 0.3)
        XCTAssertEqual(RoutingPolicy.initialVolume(remembered: 0), 0)
        XCTAssertEqual(RoutingPolicy.initialVolume(remembered: 0.43), 0.43)
    }
}
