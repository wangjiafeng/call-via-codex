// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallViaCodex",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CallViaCodex", targets: ["CallViaCodex"])],
    targets: [.executableTarget(name: "CallViaCodex", path: "Sources/CallViaCodex")]
)
