import XCTest
import Foundation
import Darwin
@testable import BoseUSBBridge

final class ControlSocketLimitsTests: XCTestCase {
    private var folder: URL!
    private var socketURL: URL!
    private var server: ControlSocket!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: "/tmp/BoseUSBBridgeLimits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        socketURL = folder.appendingPathComponent("control.sock")
    }

    override func tearDownWithError() throws {
        server?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func testConcurrentClientsAreBoundedAndCapacityRecovers() throws {
        XCTAssertEqual(ControlSocket.maximumConcurrentClients, 4)
        let fourHandlersEntered = expectation(description: "four client handlers entered")
        fourHandlersEntered.expectedFulfillmentCount = ControlSocket.maximumConcurrentClients
        let clientsFinished = expectation(description: "bounded clients finished")
        clientsFinished.expectedFulfillmentCount = ControlSocket.maximumConcurrentClients
        let releaseBlockedHandlers = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var invocationCount = 0
        var activeHandlers = 0
        var maximumActiveHandlers = 0

        server = ControlSocket(url: socketURL) { request, reply in
            stateLock.lock()
            invocationCount += 1
            let invocation = invocationCount
            activeHandlers += 1
            maximumActiveHandlers = max(maximumActiveHandlers, activeHandlers)
            stateLock.unlock()

            if invocation <= ControlSocket.maximumConcurrentClients {
                fourHandlersEntered.fulfill()
                _ = releaseBlockedHandlers.wait(timeout: .now() + 8)
            }

            stateLock.lock()
            activeHandlers -= 1
            stateLock.unlock()
            reply(["ok": true, "command": request["command"] as? String ?? ""])
            if invocation <= ControlSocket.maximumConcurrentClients { clientsFinished.fulfill() }
        }
        try server.start()

        var heldClients: [Int32] = []
        for _ in 0..<ControlSocket.maximumConcurrentClients {
            let fd = try connect(to: socketURL)
            XCTAssertTrue(writeAll(fd, data: Data("{\"command\":\"status\"}\n".utf8)))
            heldClients.append(fd)
        }
        wait(for: [fourHandlersEntered], timeout: 3)

        for _ in 0..<12 {
            let fd = try connect(to: socketURL)
            _ = writeAll(fd, data: Data("{\"command\":\"status\"}\n".utf8))
            close(fd)
        }
        Thread.sleep(forTimeInterval: 0.15)
        stateLock.lock()
        let peak = maximumActiveHandlers
        stateLock.unlock()
        XCTAssertLessThanOrEqual(peak, ControlSocket.maximumConcurrentClients)

        for _ in 0..<ControlSocket.maximumConcurrentClients { releaseBlockedHandlers.signal() }
        wait(for: [clientsFinished], timeout: 3)
        for fd in heldClients { close(fd) }

        var recovered = false
        let recoveryDeadline = Date().addingTimeInterval(2)
        while Date() < recoveryDeadline {
            let response = ControlSocket.send(command: "status", to: socketURL, timeout: 1)
            if response["ok"] as? Bool == true {
                recovered = true
                break
            }
            usleep(10_000)
        }
        XCTAssertTrue(recovered, "capacity should recover shortly after the last reply is closed")
        stateLock.lock()
        let finalPeak = maximumActiveHandlers
        stateLock.unlock()
        XCTAssertLessThanOrEqual(finalPeak, ControlSocket.maximumConcurrentClients)
    }

    func testStopKeepsAcceptedReplyAliveAndIsIdempotent() throws {
        let handlerEntered = expectation(description: "accepted request reached handler")
        let replyLock = NSLock()
        var pendingReply: (([String: Any]) -> Void)?
        server = ControlSocket(url: socketURL) { _, reply in
            replyLock.lock()
            pendingReply = reply
            replyLock.unlock()
            handlerEntered.fulfill()
        }
        try server.start()

        let client = try connect(to: socketURL)
        XCTAssertTrue(writeAll(client, data: Data("{\"command\":\"shutdown\"}\n".utf8)))
        wait(for: [handlerEntered], timeout: 2)
        server.stop()
        server.stop()

        replyLock.lock()
        let reply = pendingReply
        replyLock.unlock()
        XCTAssertNotNil(reply)
        reply?(["ok": true, "status": "종료됨"])

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let response = try readResponse(client)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["status"] as? String, "종료됨")
        close(client)

        let unavailable = ControlSocket.send(command: "status", to: socketURL, timeout: 1)
        XCTAssertEqual(unavailable["ok"] as? Bool, false)
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
                let written = write(fd, base.advanced(by: offset), data.count - offset)
                if written < 0 { if errno == EINTR { continue }; return false }
                if written == 0 { return false }
                offset += written
            }
            return true
        }
    }

    private func readResponse(_ fd: Int32) throws -> [String: Any] {
        var bytes = [UInt8](repeating: 0, count: ControlSocket.maximumMessageSize)
        let count = recv(fd, &bytes, bytes.count, 0)
        XCTAssertGreaterThan(count, 0)
        let line = Data(bytes[..<max(0, count)]).prefix { $0 != 0x0A }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
    }
}
