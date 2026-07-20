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
        .library(name: "MeroKitUI", targets: ["MeroKitUI"]),
        .executable(name: "MeroExample", targets: ["MeroExample"]),
    ],
    targets: [
        .target(
            name: "MeroKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // SwiftUI "frontend" layer: an observable MeroClient + Login/Home views.
        // The native analog of mero-react's MeroProvider/useMero + LoginModal.
        .target(
            name: "MeroKitUI",
            dependencies: ["MeroKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // A runnable end-to-end example that exercises the whole SDK.
        .executableTarget(
            name: "MeroExample",
            dependencies: ["MeroKit"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // Reusable test doubles: a URLProtocol stub + a stateful fake node
        // (nock/msw analog). Shared by every test target below.
        .target(
            name: "MeroKitTestSupport",
            dependencies: ["MeroKit"]
        ),
        // Unit tests + fully-mocked end-to-end journeys (no node required).
        .testTarget(
            name: "MeroKitTests",
            dependencies: ["MeroKit", "MeroKitTestSupport"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // View-model tests for the SwiftUI frontend (fast; no simulator needed).
        .testTarget(
            name: "MeroKitUITests",
            dependencies: ["MeroKit", "MeroKitUI", "MeroKitTestSupport"],
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
