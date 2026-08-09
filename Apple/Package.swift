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
        .executable(name: "briefly-migrate", targets: ["BrieflyMigrate"]),
        .executable(name: "briefly-mcp", targets: ["BrieflyMCP"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            from: "0.11.0"
        )
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
        .executableTarget(
            name: "BrieflyMCP",
            dependencies: [
                "BrieflyCore",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "BrieflyCoreTests",
            dependencies: ["BrieflyCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
