// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SharedLibrary",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SharedLibrary", targets: ["SharedLibrary"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
        .package(url: "https://github.com/johnxnguyen/Down.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "SharedLibrary",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Down", package: "Down")
            ],
            path: "Sources/SharedLibrary",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SharedLibraryTests",
            dependencies: ["SharedLibrary"],
            path: "Tests/SharedLibraryTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
