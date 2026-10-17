// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Screengrab",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Screengrab", path: "Sources/Screengrab",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ScreengrabTests", dependencies: ["Screengrab"], path: "Tests/ScreengrabTests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
