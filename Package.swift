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
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.1/librime.xcframework.zip",
            checksum: "98a4fce2360fb5c4b51312cc84058889eb7951ffe8b5c04a65d59cc1fef2235f"
        )
    ]
)
