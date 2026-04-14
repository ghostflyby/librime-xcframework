// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11),
        .iOS(.v13)
    ],
    products: [
        .library(name: "Rime", targets: ["Rime"]),
        .library(name: "RimeStatic", targets: ["RimeStatic"]),
        .library(name: "RimeDynamic", targets: ["RimeDynamic"])
    ],
    traits: [
        .default(enabledTraits: ["static"]),
        .init(name: "static", description: "Use the static librime XCFramework for the Rime shim."),
        .init(name: "dynamic", description: "Use the dynamic librime XCFramework for the Rime shim.")
    ],
    targets: [
        .target(
            name: "Rime",
            dependencies: [
                .target(name: "RimeStatic", condition: .when(traits: ["static"])),
                .target(name: "RimeDynamic", condition: .when(traits: ["dynamic"]))
            ],
            swiftSettings: [
                .define("RIME_USE_DYNAMIC", .when(traits: ["dynamic"]))
            ]
        ),
        .binaryTarget(
            name: "RimeStatic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.6/librime.xcframework.zip",
            checksum: "c82df737a26e72ae4898c3b02e7c1c360c3bde63e9c50faae7bc1ba9c7745359"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.6/librime-dynamic.xcframework.zip",
            checksum: "6418186725248e862d18c54a4387373589201d3672c3a89d78319abb026406e3"
        )
    ]
)
