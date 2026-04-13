// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "Rime", targets: ["Rime"]),
        .library(name: "RimeDynamic", targets: ["RimeDynamic"])
    ],
    targets: [
        .binaryTarget(
            name: "Rime",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.3/librime.xcframework.zip",
            checksum: "9fea58e802b9a90bab6a4a43485c64466bfdcd66ea992913b782ebd5f07a1ed0"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.3/librime-dynamic.xcframework.zip",
            checksum: "4d5e27690366a7e68284dbed96ea8499bd65275a0b74d3e07134419a4144aa27"
        )
    ]
)
