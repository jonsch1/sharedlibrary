// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BrieflyCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BrieflyCore", targets: ["BrieflyCore"]),
        .executable(name: "briefly-migrate", targets: ["BrieflyMigrate"])
    ],
    targets: [
        .target(
            name: "BrieflyCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "BrieflyMigrate",
            dependencies: ["BrieflyCore"]
        ),
        .testTarget(
            name: "BrieflyCoreTests",
            dependencies: ["BrieflyCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
