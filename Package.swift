// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dockduo",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Dockduo"),
        .testTarget(name: "DockduoTests", dependencies: ["Dockduo"]),
    ],
    swiftLanguageModes: [.v5]
)
