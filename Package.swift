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
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.2/librime.xcframework.zip",
            checksum: "d85f431098a3ce82596a98a5c6d93022b160ef62a8dedaee42362748647ce75f"
        )
    ]
)
