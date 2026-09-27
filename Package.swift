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
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.9.1.0/librime-static.xcframework.zip",
            checksum: "d4ccb0ebdc36877db3d9ca0f1aa5901816997a17373e31650db6c8d4d0b06a84"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.9.1.0/librime-dynamic.xcframework.zip",
            checksum: "25a80fbb6245db91b8e7982a5368a217df449be60f1f4d5c2eec3d7c755ee906"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
