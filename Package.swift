// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GoldenPassport",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "GoldenPassportCore"),
        .executableTarget(name: "GoldenPassport", dependencies: ["GoldenPassportCore"]),
        .testTarget(name: "GoldenPassportCoreTests", dependencies: ["GoldenPassportCore"]),
    ],
    swiftLanguageModes: [.v5]
)
