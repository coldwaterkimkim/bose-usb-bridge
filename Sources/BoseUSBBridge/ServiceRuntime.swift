import Foundation

enum ServiceRuntime {
    static let version = "0.2.1"
    static let identifier = "local.codex.BoseUSBBridge"
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BoseUSBBridge", isDirectory: true)
    static let socketURL = supportDirectory.appendingPathComponent("control.sock")
    static let lockURL = supportDirectory.appendingPathComponent("service.lock")
    static let diagnosticsURL = supportDirectory.appendingPathComponent("status.json")
}

struct BridgeState: Equatable {
    var statusText = "연결 대기"
    var detailText = "Bose를 USB로 연결하면 자동으로 준비합니다."
    var active = false
    var busy = false
    var connected = false
    var autoEnabled = true
    var manualOverride = false
}
