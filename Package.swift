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
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.4/librime.xcframework.zip",
            checksum: "aa2f93d23264d93546eb06bb898102f85d3c4d3f0c3e3be9407eb934c2e44880"
        ),
        .binaryTarget(
            name: "RimeDynamic",
            url: "https://github.com/ghostflyby/librime-xcframework/releases/download/1.16.1-pack.4/librime-dynamic.xcframework.zip",
            checksum: "01a448dba1ce042d13fa2e54a0125792e62e13430c58479e8f47d4e001d2e249"
        )
    ]
)
