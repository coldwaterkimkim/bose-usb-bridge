import Foundation
import Dispatch
import Darwin

private final class HeadlessBridgeService {
    private let engine = BridgeEngine()
    private var mutatingRequestActive = false
    private var stopping = false
    private var lockDescriptor: Int32 = -1
    private var control: ControlSocket?
    private var signalSources: [DispatchSourceSignal] = []
    private struct PendingRequest {
        let evaluate: (BridgeState) -> [String: Any]?
        let reply: ([String: Any]) -> Void
        let timeout: DispatchWorkItem
    }
    private var pendingRequest: PendingRequest?

    func run() throws {
        umask(0o077)
        try FileManager.default.createDirectory(at: ServiceRuntime.supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ServiceRuntime.supportDirectory.path)
        lockDescriptor = open(ServiceRuntime.lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lockDescriptor >= 0 else { throw Self.posixError("lock open") }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(lockDescriptor); lockDescriptor = -1
            throw NSError(domain: "BoseUSBBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "서비스가 이미 실행 중입니다."])
        }
        let server = ControlSocket(url: ServiceRuntime.socketURL) { [weak self] request, reply in
            DispatchQueue.main.async { self?.handle(request, reply: reply) }
        }
        try server.start()
        control = server
        installSignalHandlers()
        engine.onChange = { [weak self] state in self?.completePendingRequest(state) }
        engine.start()
        RunLoop.main.run()
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in self?.stopAfterSignal() }
            source.resume()
            signalSources.append(source)
        }
    }

    private func stopAfterSignal() {
        guard !stopping else { return }
        stopping = true
        if let pending = pendingRequest {
            pendingRequest = nil; pending.timeout.cancel()
            completeMutation(["ok": false, "error": "서비스가 종료 중입니다."], reply: pending.reply)
        }
        engine.shutdown { [weak self] in
            guard let self else { exit(EXIT_SUCCESS) }
            self.logShutdownCleanupIfNeeded()
            self.finishAndExit(status: EXIT_SUCCESS)
        }
    }

    private func handle(_ request: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let command = request["command"] as? String else {
            reply(["ok": false, "error": "잘못된 요청입니다."])
            return
        }
        guard ["status", "normal", "resume", "shutdown"].contains(command) else {
            reply(["ok": false, "error": "지원하지 않는 명령입니다."])
            return
        }
        if command == "status" {
            reply(liveStatus())
            return
        }
        guard !mutatingRequestActive, !stopping else {
            reply(["ok": false, "error": stopping ? "서비스가 종료 중입니다." : "다른 제어 작업이 진행 중입니다."])
            return
        }
        mutatingRequestActive = true
        switch command {
        case "normal": beginNormal(reply: reply)
        case "resume": beginResume(reply: reply)
        case "shutdown": beginShutdown(reply: reply)
        default: completeMutation(["ok": false, "error": "지원하지 않는 명령입니다."], reply: reply)
        }
    }

    private func beginNormal(reply: @escaping ([String: Any]) -> Void) {
        engine.returnToNormal()
        waitForState(reply: reply) { state in
            guard !state.busy else { return nil }
            if state.statusText == "복귀 확인 필요" { return ["ok": false, "error": state.detailText] }
            if state.statusText == "일반 모드" || state.statusText == "연결 대기" {
                return ["ok": true, "status": state.statusText, "detail": state.detailText]
            }
            return nil
        }
    }

    private func beginResume(reply: @escaping ([String: Any]) -> Void) {
        if engine.state.autoEnabled { engine.retry() }
        else { engine.setAutomaticEnabled(true) }
        waitForState(reply: reply) { state in
            guard !state.busy else { return nil }
            if state.statusText == "USB 전환 중단" || state.statusText == "복귀 확인 필요" {
                return ["ok": false, "error": state.detailText]
            }
            if state.active || (!state.connected && state.statusText == "연결 대기") {
                return ["ok": true, "status": state.statusText, "detail": state.detailText]
            }
            return nil
        }
    }

    private func beginShutdown(reply: @escaping ([String: Any]) -> Void) {
        stopping = true
        engine.shutdown { [weak self] in
            guard let self else { reply(["ok": false, "error": "서비스 상태를 확인할 수 없습니다."]); return }
            self.control?.stop()
            let cleanupFailed = self.engine.state.statusText == "복귀 확인 필요"
            let result: [String: Any] = cleanupFailed
                ? ["ok": false, "status": self.engine.state.statusText, "error": self.engine.state.detailText]
                : ["ok": true, "status": "종료됨"]
            self.completeMutation(result, reply: { response in
                reply(response)
                // This was an intentional service shutdown. A restore failure
                // is reported to the caller but must not trigger a KeepAlive loop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.finishAndExit(status: EXIT_SUCCESS) }
            })
        }
    }

    private func logShutdownCleanupIfNeeded() {
        guard engine.state.statusText == "복귀 확인 필요" else { return }
        fputs("BoseUSBBridge: 종료 시 정상 모드 복귀 확인 실패: \(engine.state.detailText)\n", stderr)
    }

    private func waitForState(reply: @escaping ([String: Any]) -> Void, evaluate: @escaping (BridgeState) -> [String: Any]?) {
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingRequest else { return }
            self.pendingRequest = nil
            self.completeMutation(["ok": false, "error": "작업 완료를 확인하지 못했습니다. 현재 상태를 다시 조회해 주세요."], reply: pending.reply)
        }
        pendingRequest = PendingRequest(evaluate: evaluate, reply: reply, timeout: timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 48, execute: timeout)
        completePendingRequest(engine.state)
    }

    private func completePendingRequest(_ state: BridgeState) {
        guard let pending = pendingRequest, let result = pending.evaluate(state) else { return }
        pendingRequest = nil; pending.timeout.cancel()
        completeMutation(result, reply: pending.reply)
    }

    private func completeMutation(_ response: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        mutatingRequestActive = false
        var result = response
        result["running"] = !stopping
        reply(result)
    }

    private func liveStatus() -> [String: Any] {
        let state = engine.state
        let defaults = UserDefaults(suiteName: "local.codex.BoseUSBBridge")
        return ["ok": true, "running": true, "version": ServiceRuntime.version,
                "status": state.statusText, "detail": state.detailText, "active": state.active,
                "busy": state.busy, "connected": state.connected, "automatic": state.autoEnabled,
                "manualOverride": state.manualOverride, "defaultOutput": AudioDevices.current()?.name ?? "없음",
                "rememberedVolume": defaults?.object(forKey: "rememberedVolume") ?? NSNull(),
                "firmwareWrites": false]
    }

    private func finishAndExit(status: Int32) {
        control?.stop()
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
        if lockDescriptor >= 0 { _ = flock(lockDescriptor, LOCK_UN); close(lockDescriptor); lockDescriptor = -1 }
        fflush(stdout); fflush(stderr)
        exit(status)
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }
}

private func printJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else { print("{\"ok\":false,\"error\":\"응답을 인코딩하지 못했습니다.\"}"); return }
    print(string)
}

private func stoppedStatus() -> [String: Any] {
    var result: [String: Any] = ["ok": true, "running": false, "version": ServiceRuntime.version, "status": "서비스 중지"]
    if let data = try? Data(contentsOf: ServiceRuntime.diagnosticsURL),
       let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        var lastKnown: [String: Any] = [:]
        for key in ["status", "detail", "active", "busy", "connected", "automatic", "manualHold", "outputOverride"] {
            if let value = stored[key] { lastKnown[key] = value }
        }
        result["lastKnownState"] = lastKnown
        result["lastKnown"] = true
    } else { result["lastKnown"] = false }
    result["running"] = false
    return result
}

private func runCommandLine() {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 1, let command = args.first,
          ["run", "status", "normal", "resume", "shutdown"].contains(command) else {
        fputs("사용법: BoseUSBBridge run|status|normal|resume|shutdown\n", stderr)
        exit(2)
    }
    if command == "run" {
        let service = HeadlessBridgeService()
        do { try withExtendedLifetime(service) { try service.run() } }
        catch {
            fputs("BoseUSBBridge: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        return
    }
    let response = ControlSocket.send(command: command, to: ServiceRuntime.socketURL, timeout: command == "status" ? 2 : 52)
    if command == "status", response["ok"] as? Bool != true {
        printJSON(stoppedStatus())
        exit(EXIT_SUCCESS)
    }
    printJSON(response)
    exit((response["ok"] as? Bool == true) ? EXIT_SUCCESS : 1)
}

@main
private struct BoseUSBBridgeMain {
    static func main() { runCommandLine() }
}
