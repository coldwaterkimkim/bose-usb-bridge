import XCTest
@testable import BoseUSBBridge

final class DiagnosticsTests: XCTestCase {
    func testUnchangedSnapshotDoesNotRewriteAndHistoryIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let diagnostics = Diagnostics(url: url)
        for index in 0..<105 { diagnostics.record("event_\(index)") }
        XCTAssertTrue(diagnostics.write(["active": true]))
        XCTAssertFalse(diagnostics.write(["active": true]))
        let data = try Data(contentsOf: url)
        let content = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(content["events"] as? [[String: String]])
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?["event"], "event_5")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testImmediateFlushCancelsStaleScheduledSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("status.json")
        let diagnostics = Diagnostics(url: url)
        diagnostics.schedule { ["status": "starting"] }
        XCTAssertTrue(diagnostics.write(["status": "stopped"]))
        let done = expectation(description: "scheduled snapshot remains cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let data = try? Data(contentsOf: url)
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            XCTAssertEqual(object?["status"] as? String, "stopped")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
