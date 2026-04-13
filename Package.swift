// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11),
        .iOS(.v13)
    ],
    products: [
        .library(name: "Rime", targets: ["Rime"]),
        .library(name: "RimeDynamic", targets: ["RimeDynamic"])
    ],
    targets: [
        .binaryTarget(
            name: "Rime",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.5/librime.xcframework.zip",
            checksum: "653f4014a4e593addc3126ca30adfba28655bab19af0a9ad0842fa30315c86a2"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.5/librime-dynamic.xcframework.zip",
            checksum: "81122a83518af3128c38bf887ee83b012f1c4b5e0e1447a71d44b94b91e43f41"
        )
    ]
)
