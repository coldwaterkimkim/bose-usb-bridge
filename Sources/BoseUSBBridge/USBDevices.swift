import Foundation
import IOKit
import CoreFoundation

struct USBIdentity: Equatable {
    let productID: Int
    let registryID: UInt64
    let locationID: Int

    static func supports(vendorID: Int, productID: Int) -> Bool {
        vendorID == 0x05a7 && (productID == 0x40fe || productID == 0x40fa)
    }
}

enum USBInventory {
    private static let vendorKey = "idVendor" as CFString
    private static let productKey = "idProduct" as CFString
    private static let locationKey = "locationID" as CFString

    static func devices() -> [USBIdentity] {
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [USBIdentity] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard IOObjectConformsTo(service, "IOUSBHostDevice") != 0 else { continue }
            func number(_ key: CFString) -> Int {
                (IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue ?? -1
            }
            let pid = number(productKey), vid = number(vendorKey)
            guard USBIdentity.supports(vendorID: vid, productID: pid) else { continue }
            var rid: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &rid)
            found.append(USBIdentity(productID: pid, registryID: rid, locationID: number(locationKey)))
        }
        return found
    }
}

final class USBWatcher {
    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    var changed: (() -> Void)?
    private(set) var isActive = false
    init(changed: @escaping () -> Void) {
        self.changed = changed
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let callback: IOServiceMatchingCallback = { context, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            if let context { Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue().changed?() }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let addMatch = Self.boseVendorMatch(), let removeMatch = Self.boseVendorMatch() else { stop(); return }
        let addResult = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, addMatch, callback, context, &added)
        let removeResult = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, removeMatch, callback, context, &removed)
        guard addResult == KERN_SUCCESS, removeResult == KERN_SUCCESS else { stop(); return }
        isActive = true
        while case let s = IOIteratorNext(added), s != 0 { IOObjectRelease(s) }
        while case let s = IOIteratorNext(removed), s != 0 { IOObjectRelease(s) }
    }
    private static func boseVendorMatch() -> CFMutableDictionary? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        let propertyMatchKey = "IOPropertyMatch" as CFString
        let properties = ["idVendor": NSNumber(value: 0x05a7)] as CFDictionary
        // CFDictionarySetValue retains both objects through the dictionary's
        // callbacks. Keep the Swift bridge objects alive across that call too;
        // otherwise -Osize may end the temporary CFString lifetime early.
        withExtendedLifetime(propertyMatchKey) {
            withExtendedLifetime(properties) {
                CFDictionarySetValue(matching,
                                     Unmanaged.passUnretained(propertyMatchKey).toOpaque(),
                                     Unmanaged.passUnretained(properties).toOpaque())
            }
        }
        return matching
    }
    func stop() {
        isActive = false
        if added != 0 { IOObjectRelease(added); added = 0 }
        if removed != 0 { IOObjectRelease(removed); removed = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
    }
    deinit {
        stop()
    }
}
