import Foundation
import IOKit
import IOKit.pwr_mgt

private enum PowerMessage {
    // IOKit.h's function-like iokit_common_msg macro is not imported by Swift.
    // These are the published constants expanded from IOReturn.h/IOMessage.h.
    static let canSystemSleep: UInt32 = 0xE0000270
    static let systemWillSleep: UInt32 = 0xE0000280
    static let systemHasPoweredOn: UInt32 = 0xE0000300
}

/// Delivers completed system wake events on the main queue and immediately
/// acknowledges the sleep messages required by IOPMrootDomain.
final class SystemWakeObserver {
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL
    private var rootPort: io_connect_t = IO_OBJECT_NULL
    private let onWake: () -> Void
    private(set) var isActive = false

    init?(onWake: @escaping () -> Void) {
        self.onWake = onWake
        var port: IONotificationPortRef?
        var token: io_object_t = IO_OBJECT_NULL
        let connection = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &port,
            Self.powerCallback,
            &token
        )
        guard connection != IO_OBJECT_NULL, let port else {
            if let port { IONotificationPortDestroy(port) }
            return nil
        }
        notificationPort = port
        notifier = token
        rootPort = connection
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        isActive = true
    }

    private static let powerCallback: IOServiceInterestCallback = { context, _, messageType, messageArgument in
        guard let context else { return }
        Unmanaged<SystemWakeObserver>.fromOpaque(context).takeUnretainedValue()
            .handle(messageType: messageType, argument: messageArgument)
    }

    private func handle(messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        if messageType == PowerMessage.canSystemSleep || messageType == PowerMessage.systemWillSleep {
            _ = IOAllowPowerChange(rootPort, argument.map { Int(bitPattern: $0) } ?? 0)
        } else if messageType == PowerMessage.systemHasPoweredOn {
            DispatchQueue.main.async { [onWake] in onWake() }
        }
    }

    func stop() {
        guard isActive || notificationPort != nil || rootPort != IO_OBJECT_NULL else { return }
        isActive = false
        if notifier != IO_OBJECT_NULL {
            _ = IODeregisterForSystemPower(&notifier)
            notifier = IO_OBJECT_NULL
        }
        if rootPort != IO_OBJECT_NULL {
            _ = IOServiceClose(rootPort)
            rootPort = IO_OBJECT_NULL
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
    }

    deinit { stop() }
}
