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
        .library(name: "RimeSystem", targets: ["RimeSystem"]),
        .library(name: "RimeOpenCCData", targets: ["RimeOpenCCData"])
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
        .target(
            name: "RimeOpenCCData",
            path: "Sources/RimeOpenCCData",
            resources: [
                .copy("opencc")
            ]
        ),
        .binaryTarget(
            name: "RimeStatic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.18.0-pack.0.0.0/librime-static.xcframework.zip",
            checksum: "9abea526a506ca343bdd46faef76af7cd5281f545232057596b0b094e1486194"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.18.0-pack.0.0.0/librime-dynamic.xcframework.zip",
            checksum: "561579d6adf2052ec7c57624537cd192af812ff20d5e1ce2da090c9aca67a2b9"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
