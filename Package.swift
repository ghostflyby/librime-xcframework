// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11),
        .iOS(.v15)
    ],
    products: [
        .library(name: "Rime", targets: ["RimeHeaders"]),
        .library(name: "RimeStatic", targets: ["RimeStatic"]),
        .library(name: "RimeDynamic", targets: ["RimeDynamic"]),
        .library(name: "RimeDynamicStub", targets: ["RimeDynamicStub"]),
        .library(name: "RimeSystem", targets: ["RimeSystem"])
    ],
    targets: [
        .systemLibrary(
            name: "RimeHeaders",
            path: "Sources/RimeHeaders/include"
        ),
        .target(
            name: "RimeDynamicStub",
            path: "Sources/RimeDynamicStub",
            linkerSettings: [
                .linkedFramework("RimeDynamic")
            ]
        ),
        .binaryTarget(
            name: "RimeStatic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.9.0.2/librime-static.xcframework.zip",
            checksum: "e05607222219edb63129b72741c6b68f1f168f08db4026e19577d98fa2733655"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.9.0.2/librime-dynamic.xcframework.zip",
            checksum: "1cdf345d38b0a6a7064c4615c67586b5554c448c494c8cf3dc1434c59c05aac8"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
