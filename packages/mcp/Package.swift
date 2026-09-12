// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BrieflyMCP",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "briefly-mcp", targets: ["BrieflyMCP"])],
    dependencies: [
        .package(path: "../apple"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "BrieflyMCP",
            dependencies: [
                .product(name: "BrieflyCore", package: "apple"),
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
