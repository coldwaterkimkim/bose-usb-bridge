// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BoseUSBBridge", platforms: [.macOS(.v14)], products: [.executable(name: "BoseUSBBridge", targets: ["BoseUSBBridge"])], targets: [
    .executableTarget(name: "BoseUSBBridge", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreAudio")]),
    .testTarget(name: "BoseUSBBridgeTests", dependencies: ["BoseUSBBridge"])
])
