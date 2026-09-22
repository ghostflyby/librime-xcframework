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
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.9.0.0/librime-static.xcframework.zip",
            checksum: "464464e02484bdd1121fe213539a32f1b5cc51e79bbef011c61663242b7d45b1"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.17.0-pack.9.0.0/librime-dynamic.xcframework.zip",
            checksum: "c9169a0f9caaa68567a85884cde37fd7da53defad2e12a1e2d185e1651328905"
        ),
        .systemLibrary(
            name: "RimeSystem",
            path: "Sources/RimeSystem",
            pkgConfig: "rime"
        )
    ]
)
