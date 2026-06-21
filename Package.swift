// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fathom",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "Fathom", targets: ["Fathom"])
    ],
    targets: [
        .target(
            name: "Fathom",
            path: "Sources/Fathom"
        ),
        .testTarget(
            name: "FathomTests",
            dependencies: ["Fathom"],
            path: "Tests/FathomTests"
        )
    ]
)
