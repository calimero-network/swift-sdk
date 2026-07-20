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
        .executable(name: "MeroExample", targets: ["MeroExample"]),
    ],
    targets: [
        .target(
            name: "MeroKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // A runnable end-to-end example that exercises the whole SDK. Runs an
        // offline demo with no config, or a full online flow when MERO_NODE_URL
        // (+ MERO_USERNAME / MERO_PASSWORD) are set. See `swift run MeroExample`.
        .executableTarget(
            name: "MeroExample",
            dependencies: ["MeroKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // Unit tests + fully-mocked end-to-end journeys (no node required).
        .testTarget(
            name: "MeroKitTests",
            dependencies: ["MeroKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // Real end-to-end tests against a live node. Skipped automatically unless
        // MERO_E2E_NODE_URL is set (see .github/workflows/e2e.yml).
        .testTarget(
            name: "MeroKitE2ETests",
            dependencies: ["MeroKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ]
)
