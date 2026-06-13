// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PassSync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PassSyncApp", targets: ["PassSyncMac"]),
        .executable(name: "passsync", targets: ["passsync"]),
        .library(name: "PassSyncCore", targets: ["PassSyncCore"])
    ],
    targets: [
        .target(
            name: "PassSyncCore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "passsync",
            dependencies: ["PassSyncCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "PassSyncMac",
            dependencies: ["PassSyncCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "PassSyncCoreTests",
            dependencies: ["PassSyncCore"]
        )
    ]
)
