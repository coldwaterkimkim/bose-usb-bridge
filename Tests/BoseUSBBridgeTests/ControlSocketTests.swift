import XCTest
import Foundation
import Darwin
@testable import BoseUSBBridge

final class ControlSocketTests: XCTestCase {
    private var folder: URL!
    private var socketURL: URL!
    private var server: ControlSocket!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/tmp/BoseUSBBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        socketURL = folder.appendingPathComponent("control.sock")
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func testStatusCommandReturnsJSONResponse() throws {
        try startServer { request, reply in
            reply(["ok": true, "command": request["command"] as? String ?? ""])
        }

        let response = ControlSocket.send(command: "status", to: socketURL, timeout: 2)
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertEqual(response["command"] as? String, "status")
    }

    func testServerRejectsInvalidCommand() throws {
        try startServer { _, reply in reply(["ok": true]) }

        let response = try rawRequest("{\"command\":\"exec\"}", at: socketURL)
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertNotNil(response["error"] as? String)
    }

    func testServerRejectsOversizedRequest() throws {
        try startServer { _, reply in reply(["ok": true]) }

        let oversized = "{\"command\":\"status\",\"padding\":\"" + String(repeating: "x", count: ControlSocket.maximumMessageSize) + "\"}"
        let response = try rawRequest(oversized, at: socketURL)
        XCTAssertEqual(response["ok"] as? Bool, false)
    }

    func testDisconnectedClientDoesNotTerminateServerOnReply() throws {
        let replied = expectation(description: "server attempted reply to disconnected client")
        let firstRequestLock = NSLock()
        var firstRequest = true
        try startServer { request, reply in
            firstRequestLock.lock()
            let isFirstRequest = firstRequest
            firstRequest = false
            firstRequestLock.unlock()
            guard isFirstRequest else {
                reply(["ok": true, "command": request["command"] as? String ?? ""])
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                reply(["ok": true, "command": request["command"] as? String ?? ""])
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { replied.fulfill() }
            }
        }

        let client = try connect(to: socketURL)
        XCTAssertTrue(writeAll(client, data: Data("{\"command\":\"status\"}\n".utf8)))
        close(client)
        wait(for: [replied], timeout: 3)

        // A fresh connection succeeding proves the service is still accepting
        // requests after its reply write to the departed client.
        let probe = try connect(to: socketURL)
        close(probe)
    }

    private func startServer(handler: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void) throws {
        server = ControlSocket(url: socketURL, handler: handler)
        try server.start()
    }

    private func rawRequest(_ message: String, at url: URL) throws -> [String: Any] {
        let fd = try connect(to: url)
        defer { close(fd) }
        var data = Data(message.utf8)
        data.append(0x0A)
        XCTAssertTrue(writeAll(fd, data: data))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = recv(fd, &bytes, bytes.count, 0)
        XCTAssertGreaterThan(count, 0)
        let responseData = Data(bytes[..<max(count, 0)])
        let responseLine = responseData.prefix { $0 != 0x0A }
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(responseLine)) as? [String: Any])
        return response
    }

    private func connect(to url: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var noPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(url.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            close(fd)
            throw error
        }
        return fd
    }

    private func writeAll(_ fd: Int32, data: Data) -> Bool {
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
}
