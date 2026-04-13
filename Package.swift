// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "Rime", targets: ["Rime"])
    ],
    targets: [
        .binaryTarget(
            name: "Rime",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/test-2/librime.xcframework.zip",
            checksum: "557b20bd795acfbf1f526f1df77511086af803d5683fc785678bf792395b71d1"
        )
    ]
)
