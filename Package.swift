// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11),
        .iOS(.v13)
    ],
    products: [
        .library(name: "RimeStatic", targets: ["RimeStatic"]),
        .library(name: "RimeDynamic", targets: ["RimeDynamic"]),
        .library(name: "RimeSystem", targets: ["RimeSystem"])
    ],
    targets: [
        .binaryTarget(
            name: "RimeStatic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.8/librime-static.xcframework.zip",
            checksum: "25f4cd03c6c22a6e41504b567f26928491e9f767c22a9dd6b8697e205a0cadc0"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.8/librime-dynamic.xcframework.zip",
            checksum: "9c65fb3f1ba127751e33fa72104489c5667ef7dc37b483196fa4d69dcda50e48"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
