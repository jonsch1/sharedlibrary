// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BrieflyCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BrieflyCore", targets: ["BrieflyCore"])
    ],
    targets: [
        .target(
            name: "BrieflyCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "BrieflyCoreTests",
            dependencies: ["BrieflyCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
