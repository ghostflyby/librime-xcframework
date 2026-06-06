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
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.1/librime-static.xcframework.zip",
            checksum: "0f0fc13b9c03448ac3a4eb8c325efdb4df60be6e7a859fcc5080571f961f1164"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.1/librime-dynamic.xcframework.zip",
            checksum: "0d6630a176e3430817af6228c66cb55534fe990d55ce16aab272c007cffea4f0"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
