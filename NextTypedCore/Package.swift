// swift-tools-version: 6.0
import PackageDescription

// NextTypedCore: the pure, AppKit/AX-free logic of NextTyped.
// Fast to build and test in isolation.
let package = Package(
    name: "NextTypedCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NextTypedCore", targets: ["NextTypedCore"]),
    ],
    targets: [
        .target(
            name: "NextTypedCore",
            resources: [.copy("Resources/emoji-lexicon.lzfse")]
        ),
        .testTarget(
            name: "NextTypedCoreTests",
            dependencies: ["NextTypedCore"]
        ),
    ]
)
