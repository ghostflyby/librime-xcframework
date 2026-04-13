# librime XCFramework

Static and dynamic macOS/iOS XCFramework packaging for upstream `librime`.

This repository builds a binary distribution so Xcode and SwiftPM consumers do not need to compile librime and its C++ dependency graph themselves.

## Artifacts

A release contains:

- `librime.xcframework.zip`
- `librime-dynamic.xcframework.zip`
- `build-metadata.json`

The static XCFramework contains macOS arm64/x86_64, iOS device arm64, and iOS simulator arm64/x86_64 library slices. The dynamic XCFramework contains `RimeDynamic.framework` slices for macOS, iOS device, and iOS simulator. Both include the public librime C API headers. GitHub Releases exposes the SHA-256 digest for each uploaded asset.

## Swift Package

Release tags contain a generated `Package.swift` with binary targets that point at the matching GitHub Release assets.

```swift
.package(url: "https://github.com/ghostflyby/librime-xcframework.git", from: "1.16.1-pack.1")
```

Use product `Rime` for the static XCFramework and `RimeDynamic` for the dynamic framework XCFramework.

## Local Build

Prerequisites:

- macOS with Xcode command line tools
- CMake and Ninja
- vcpkg, with `VCPKG_ROOT` pointing at the vcpkg checkout
- upstream `librime` source at `../librime` or `vendor/librime`

Build and package:

```bash
VCPKG_ROOT=/path/to/vcpkg scripts/build-all.sh
```

Build one slice:

```bash
VCPKG_ROOT=/path/to/vcpkg scripts/build-one-arch.sh arm64
VCPKG_ROOT=/path/to/vcpkg scripts/build-one-arch.sh x86_64
```

Package existing slice outputs:

```bash
scripts/package-xcframework.sh
```

Outputs are written to `out/` and `dist/`.

## Versioning

Package versions use:

```text
<upstream-version>-pack.<packaging-revision>
```

In the build workflow, leaving `upstream_ref` empty builds the latest upstream release tag. Leaving `packaging_version` empty derives the release tag from the upstream version and `packaging_revision`; if `packaging_revision` is also empty, the workflow uses the next available pack revision.

Example:

```text
1.16.1-pack.1
```
