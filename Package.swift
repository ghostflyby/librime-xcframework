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
            checksum: "a33da0d80e13497bef2590b0f594d07e70730862edbd8c761f289b37130d3eb5"
        )
    ]
)
