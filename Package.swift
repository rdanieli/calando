// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Calando",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Calando",
            path: "Sources/Calando"
        ),
        .testTarget(
            name: "CalandoTests",
            dependencies: ["Calando"],
            path: "Tests/CalandoTests"
        ),
    ]
)
