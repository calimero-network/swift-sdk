// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeroKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "MeroKit", targets: ["MeroKit"]),
    ],
    targets: [
        .target(
            name: "MeroKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "MeroKitTests",
            dependencies: ["MeroKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
