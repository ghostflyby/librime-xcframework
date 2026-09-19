# librime XCFramework

Static and dynamic macOS/iOS XCFramework packaging for upstream `librime`.

This repository builds a binary distribution so Xcode and SwiftPM consumers do not need to compile librime and its C++ dependency graph themselves.

## Artifacts

A release contains:

- `librime-static.xcframework.zip`
- `librime-dynamic.xcframework.zip`
- `LICENSE.txt`
- `THIRD_PARTY_NOTICES.md`
- `third-party-notices.zip`
- `build-metadata.json`

The static XCFramework contains macOS arm64/x86_64, iOS device arm64, and iOS simulator arm64/x86_64 library slices. The dynamic XCFramework contains `RimeDynamic.framework` slices for macOS, iOS device, and iOS simulator. The macOS slice is a versioned deep bundle (`Versions/A`, install name `@rpath/RimeDynamic.framework/Versions/A/RimeDynamic`) so SwiftPM-embedded copies already satisfy macOS app validation without a post-embed fix-up script. Both include the public librime C API headers but no module maps; the `Rime` Swift module is provided by the package's headers product. GitHub Releases exposes the SHA-256 digest for each uploaded asset.

## Swift Package

Release tags contain a generated `Package.swift` with a headers target and binary targets that point at the matching GitHub Release assets.

```swift
.package(url: "https://github.com/ghostflyby/librime-xcframework.git", from: "1.16.1-pack.1")
```

All consumer source code writes `import Rime`. The `Rime` module is declared once, by product `Rime`'s headers target; the linking products below carry no module of their own and only supply the binary to link:

- `Rime` — public librime headers plus the `Rime` module only. No binaries are downloaded and nothing is linked. Wrapper libraries should depend on this product.
- `RimeDynamic` — the dynamic framework XCFramework. Xcode links and embeds it automatically for targets that declare the product.
- `RimeStatic` — the static XCFramework with librime dependencies merged into the archive. Linked automatically.
- `RimeSystem` — binds against a system-provided or user-replaced librime implementation via `pkg-config rime` flags without distributing any librime headers. It also declares the `Rime` module, so do not combine `RimeSystem` and `Rime` in the same package graph.

Wrapper libraries depend on `Rime` only. Terminal apps that use the binary artifacts depend on `Rime` plus exactly one of `RimeDynamic`/`RimeStatic` (linked automatically, or manually with `pkg-config rime` flags). Apps binding a system librime depend on `RimeSystem` alone — `RimeSystem` replaces `Rime` in the graph, never combines with it.

The modules previously shipped as `RimeStatic`, `RimeDynamic`, and `RimeSystem`; import sites must change to `import Rime` starting with the first release built from this layout.

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

## License

The packaging wrapper code in this repository is licensed under the BSD
3-Clause License. Binary release artifacts include upstream `librime`, which is
also BSD 3-Clause licensed, and may include statically linked third-party
dependencies resolved by vcpkg.

Keep `LICENSE.txt`, `THIRD_PARTY_NOTICES.md`, and `third-party-notices.zip`
with redistributed binary artifacts.
