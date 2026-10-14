// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PausePathCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PausePathCore", targets: ["PausePathCore"])],
    targets: [
        .target(name: "PausePathCore", path: "PausePath/Core"),
        .testTarget(name: "PausePathCoreTests", dependencies: ["PausePathCore"], path: "Tests/PausePathCoreTests")
    ]
)
