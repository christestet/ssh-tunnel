// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "SSHTunnel",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "SSHTunnel", targets: ["SSHTunnel"]),
        .library(name: "SSHTunnelKit", targets: ["SSHTunnelKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SSHTunnelKit",
            path: "Sources/SSHTunnelKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SSHTunnel",
            dependencies: ["SSHTunnelKit"],
            path: "Sources/SSHTunnel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SSHTunnelTests",
            dependencies: ["SSHTunnelKit"],
            path: "Tests/SSHTunnelTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
