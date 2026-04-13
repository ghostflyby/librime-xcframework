// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Librime",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .library(name: "Rime", targets: ["Rime"])
    ],
    targets: [
        .binaryTarget(
            name: "Rime",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.1/librime.xcframework.zip",
            checksum: "27f4b784b489be20dc725d166f57e6efcd2bb31afcc5c48581161bdd10233d67"
        )
    ]
)
