// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GlyphScan",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "GlyphScanCore", targets: ["GlyphScanCore"]),
    ],
    targets: [
        .target(name: "GlyphScanCore"),
        .testTarget(
            name: "GlyphScanCoreTests",
            dependencies: ["GlyphScanCore"]
        ),
    ]
)
