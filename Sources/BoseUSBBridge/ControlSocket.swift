import Foundation
import Darwin

/// A small, local-only newline-delimited JSON control channel. The socket is
/// protected by the containing user's Application Support directory and mode 0600.
final class ControlSocket {
    static let maximumMessageSize = 4096
    static let maximumConcurrentClients = 4

    private let url: URL
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "local.codex.BoseUSBBridge.control", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let clientQueue = DispatchQueue.global(qos: .utility)
    private let clientSlots = DispatchSemaphore(value: maximumConcurrentClients)
    private var cancelCompletion: DispatchSemaphore?
    private let handler: ([String: Any], @escaping ([String: Any]) -> Void) -> Void

    init(url: URL, handler: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void) {
        self.url = url
        self.handler = handler
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit { stop() }

    func start() throws {
        // The bridge owns this process; ignoring SIGPIPE provides a final guard
        // for write() on any platform socket that closes between poll and send.
        signal(SIGPIPE, SIG_IGN)
        guard descriptor < 0, source == nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EALREADY))
        }
        var address = try Self.address(for: url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.posixError("socket") }
        let socketFlags = fcntl(fd, F_GETFL)
        guard socketFlags >= 0, fcntl(fd, F_SETFL, socketFlags | O_NONBLOCK) == 0 else {
            let error = Self.posixError("fcntl")
            close(fd)
            throw error
        }
        descriptor = fd
        _ = unlink(url.path)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { let error = Self.posixError("bind"); close(fd); descriptor = -1; throw error }
        guard chmod(url.path, mode_t(0o600)) == 0 else { let error = Self.posixError("chmod"); close(fd); descriptor = -1; _ = unlink(url.path); throw error }
        guard listen(fd, 8) == 0 else { let error = Self.posixError("listen"); close(fd); descriptor = -1; _ = unlink(url.path); throw error }
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptClients() }
        let cancelDone = DispatchSemaphore(value: 0)
        readSource.setCancelHandler { close(fd); cancelDone.signal() }
        cancelCompletion = cancelDone
        source = readSource
        readSource.resume()
    }

    func stop() {
        var completion: DispatchSemaphore?
        let cancel = {
            guard self.descriptor >= 0 || self.source != nil else { return }
            if self.descriptor >= 0 { _ = unlink(self.url.path); self.descriptor = -1 }
            let oldSource = self.source
            self.source = nil
            completion = self.cancelCompletion
            self.cancelCompletion = nil
            oldSource?.cancel()
        }
        let onQueue = DispatchQueue.getSpecific(key: queueKey) != nil
        if onQueue { cancel() }
        else { queue.sync(execute: cancel) }
        if !onQueue, let completion { completion.wait() }
    }

    private func acceptClients() {
        guard descriptor >= 0 else { return }
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                return
            }
            guard clientSlots.wait(timeout: .now()) == .success else {
                _ = shutdown(client, SHUT_RDWR)
                close(client)
                continue
            }
            let clientFlags = fcntl(client, F_GETFL)
            if clientFlags >= 0 { _ = fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) }
            clientQueue.async { [self] in
                defer { close(client); clientSlots.signal() }
                autoreleasepool { serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        var noPipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let data = Self.readMessage(client) else {
            Self.writeResponse(["ok": false, "error": "요청을 읽지 못했습니다."], to: client)
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String,
              ["status", "normal", "resume", "shutdown"].contains(command) else {
            Self.writeResponse(["ok": false, "error": "잘못된 요청입니다."], to: client)
            return
        }
        let replied = DispatchSemaphore(value: 0)
        var response: [String: Any] = ["ok": false, "error": "요청 시간 초과"]
        handler(object, { result in response = result; replied.signal() })
        if replied.wait(timeout: .now() + 52) == .success {
            Self.writeResponse(response, to: client)
        } else {
            Self.writeResponse(["ok": false, "error": "요청 시간이 초과되었습니다."], to: client)
        }
    }

    static func send(command: String, to url: URL, timeout: TimeInterval = 52) -> [String: Any] {
        guard ["status", "normal", "resume", "shutdown"].contains(command),
              let addressResult = try? address(for: url.path) else {
            return ["ok": false, "error": "잘못된 명령 또는 소켓 경로입니다."]
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return ["ok": false, "error": "서비스에 연결할 수 없습니다."] }
        defer { close(fd) }
        var noPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = addressResult
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return ["ok": false, "error": "서비스가 실행 중이 아닙니다."] }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let data = try? JSONSerialization.data(withJSONObject: ["command": command]), data.count < maximumMessageSize else {
            return ["ok": false, "error": "요청을 만들 수 없습니다."]
        }
        var request = data
        request.append(0x0A)
        guard writeAll(fd, data: request), let responseData = readMessage(fd),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return ["ok": false, "error": "서비스 응답을 읽지 못했습니다."]
        }
        return response
    }

    private static func readMessage(_ fd: Int32) -> Data? {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 512)
        while data.count < maximumMessageSize {
            let count = recv(fd, &bytes, min(bytes.count, maximumMessageSize - data.count), 0)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { return data.isEmpty ? nil : data }
            if let newline = bytes[..<count].firstIndex(of: 0x0A) {
                data.append(contentsOf: bytes[..<newline])
                return data
            }
            data.append(contentsOf: bytes[..<count])
        }
        return nil
    }

    private static func writeResponse(_ object: [String: Any], to fd: Int32) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), data.count < maximumMessageSize else { return }
        var line = data
        line.append(0x0A)
        _ = writeAll(fd, data: line)
    }

    private static func writeAll(_ fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let count = write(fd, base.advanced(by: offset), data.count - offset)
                if count < 0 { if errno == EINTR { continue }; return false }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
    }

    private static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return address
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
    }
}
