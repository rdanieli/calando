// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fader",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Fader",
            path: "Sources/Fader"
        ),
        .testTarget(
            name: "FaderTests",
            dependencies: ["Fader"],
            path: "Tests/FaderTests"
        ),
    ]
)
