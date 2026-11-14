// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SafeSpotCore",
    products: [
        .library(name: "SafeSpotCore", targets: ["SafeSpotCore"]),
    ],
    targets: [
        .target(name: "SafeSpotCore"),
        .testTarget(
            name: "SafeSpotCoreTests",
            dependencies: ["SafeSpotCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
