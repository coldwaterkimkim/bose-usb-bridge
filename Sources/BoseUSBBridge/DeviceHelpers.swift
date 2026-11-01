import Foundation

final class OperationToken {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws { if cancelled { throw BridgeError("작업을 중단했습니다.") } }
}

struct HelperResult {
    var code: Int32
    var text: String
}

enum DeviceHelpers {
    private static let directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers", isDirectory: true)
    static func run(_ name: String, _ arguments: [String], timeout: TimeInterval = 10) throws -> HelperResult {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw BridgeError("앱의 장치 도구를 찾을 수 없습니다.") }
        let process = Process(), pipe = Pipe(), done = DispatchSemaphore(value: 0)
        process.executableURL = url; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
            throw BridgeError("장치 응답 시간이 초과되었습니다.")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return HelperResult(code: process.terminationStatus, text: String(data: data, encoding: .utf8) ?? "")
    }
    static func require(_ name: String, _ arguments: [String]) throws {
        let r = try run(name, arguments)
        guard r.code == 0 else {
            if r.text.contains("Main ") && !r.text.contains("Main 1.0.20.") { throw BridgeError("검증되지 않은 펌웨어입니다. 자동 전환을 멈췄습니다.") }
            throw BridgeError("장치 단계 \(name)/\(arguments.first ?? "") 실패 (\(r.code)). bose-usb resume으로 재시도할 수 있습니다.")
        }
    }
}
