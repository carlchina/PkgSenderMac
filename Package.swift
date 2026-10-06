// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PkgSenderMac",
    // Marks en as the base language; UI strings live in
    // Sources/PkgSenderApp/Resources/<lang>.lproj/Localizable.strings.
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "PkgSenderCore", targets: ["PkgSenderCore"]),
        .executable(name: "PkgSender", targets: ["PkgSenderApp"]),
    ],
    targets: [
        .target(
            name: "PkgSenderCore",
            path: "Sources/PkgSenderCore"
        ),
        .executableTarget(
            name: "PkgSenderApp",
            dependencies: ["PkgSenderCore"],
            path: "Sources/PkgSenderApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PkgSenderCoreTests",
            dependencies: ["PkgSenderCore"],
            path: "Tests/PkgSenderCoreTests"
        ),
    ]
)
