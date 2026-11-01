import XCTest
@testable import BoseUSBBridge

final class DeviceDiscoveryTests: XCTestCase {
    func testOptimizedUSBNotificationRegistrationLifetime() throws {
        // Regression for temporary CF objects released before CFDictionarySetValue.
        // Also run this suite with -c release -Xswiftc -Osize; no device is opened.
        for _ in 0..<20 {
            let watcher = USBWatcher(changed: {})
            guard watcher.isActive else { throw XCTSkip("USB notification registration unavailable on this host") }
            watcher.stop()
            XCTAssertFalse(watcher.isActive)
        }
    }

    func testBoseUSBIdentityFilterPreservesBothKnownModes() {
        XCTAssertTrue(USBIdentity.supports(vendorID: 0x05a7, productID: 0x40fe))
        XCTAssertTrue(USBIdentity.supports(vendorID: 0x05a7, productID: 0x40fa))
        XCTAssertFalse(USBIdentity.supports(vendorID: 0x05a6, productID: 0x40fe))
        XCTAssertFalse(USBIdentity.supports(vendorID: 0x05a7, productID: 0x40ff))
    }
}
