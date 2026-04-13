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
            checksum: "156d6837e792707466bd4a025552f7dcd7ae9d3dd5e5dc92022c7fd6e9ca7c81"
        )
    ]
)
