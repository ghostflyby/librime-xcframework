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
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.7/librime.xcframework.zip",
            checksum: "3e290140d21f00850c6e62e00ad6d714b92a2d49a374c38259790713eb4aefd3"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.7/librime-dynamic.xcframework.zip",
            checksum: "f2d37b5f5d09a1efc1d74164b90254b310c2c1fbcf9bc71ba0818c63a260fdd6"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
