import Foundation

struct BridgeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct RoutingSession: Codable {
    var previousUID: String?
    var previousName: String?
    var targetUID: String?
    var originalVolume: Float?
    var restoreAllowed: Bool = true
}

enum RoutingPolicy {
    static func restoreUID(session: RoutingSession, currentUID: String?, availableUIDs: Set<String>) -> String? {
        guard session.restoreAllowed, let previous = session.previousUID, previous != session.targetUID, availableUIDs.contains(previous) else { return nil }
        let targetIsPresent = session.targetUID.map { availableUIDs.contains($0) } ?? false
        guard currentUID == session.targetUID || !targetIsPresent else { return nil }
        return previous
    }
    static func initialVolume(remembered: Float?) -> Float {
        guard let remembered, remembered.isFinite, (0...1).contains(remembered) else { return 0.30 }
        return remembered
    }
}
