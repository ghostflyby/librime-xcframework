// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11),
        .iOS(.v13)
    ],
    products: [
        .library(name: "Rime", targets: ["RimeHeaders"]),
        .library(name: "RimeStatic", targets: ["RimeStatic"]),
        .library(name: "RimeDynamic", targets: ["RimeDynamic"]),
        .library(name: "RimeSystem", targets: ["RimeSystem"])
    ],
    targets: [
        .target(
            name: "RimeHeaders",
            path: "Sources/RimeHeaders"
        ),
        .binaryTarget(
            name: "RimeStatic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.4/librime-static.xcframework.zip",
            checksum: "3afaede8ee592b6729fbe938cac4678761a795ba0a4ee244744bc270dcd50914"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.4/librime-dynamic.xcframework.zip",
            checksum: "c32cdb0d04f56c4c4b3927a9cef2955ee43eb53fe7ca2b1b72619a28b9fdd966"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
