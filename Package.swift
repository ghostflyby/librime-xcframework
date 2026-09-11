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
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.2/librime-static.xcframework.zip",
            checksum: "8cdfad8b8c64ba96a7381000eddd24b33961990e3d39346c30ece153a2ca7b7a"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.2/librime-dynamic.xcframework.zip",
            checksum: "662e9482615880d09005fc35b3ace3b21558af81d1386ba9d17f37c4b983aef1"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
