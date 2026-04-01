// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shuttle",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ShuttleKit",
            targets: ["ShuttleKit"]
        ),
        .executable(
            name: "shuttle",
            targets: ["ShuttleCLI"]
        ),
        .executable(
            name: "ShuttleApp",
            targets: ["ShuttleApp"]
        ),
    ],
    targets: [
        // GhosttyKit xcframework — provides libghostty C API + GPU-accelerated terminal
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        .target(
            name: "ShuttleKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "ShuttleCLI",
            dependencies: ["ShuttleKit"]
        ),
        .executableTarget(
            name: "ShuttleApp",
            dependencies: ["ShuttleKit", "GhosttyKit"],
            resources: [
                .process("Resources/shell-integration")
            ],
            linkerSettings: [
                // libghostty depends on system frameworks
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Carbon"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "ShuttleKitTests",
            dependencies: ["ShuttleKit"]
        ),
    ]
)
