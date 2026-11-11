// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Splat3D",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "Splat3D",
            targets: ["Splat3D"]
        ),
    ],
    targets: [
        .target(
            name: "Splat3D",
            path: "Sources/Splat3D"
        ),
        .testTarget(
            name: "Splat3DTests",
            dependencies: ["Splat3D"],
            path: "Tests/Splat3DTests",
            resources: [.copy("Fixtures")]
        ),
        // The example app's tap-to-point math and its tests. The app has no
        // test target of its own, so `swift test` runs them from here.
        .testTarget(
            name: "PickGeometryTests",
            path: "Examples/SplatCapture/PickGeometry"
        ),
    ]
)
