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

All consumer source code writes `import Rime`. The `Rime` module is declared once, by product `Rime`'s headers target; the linking products below supply only the binary to link, not a module consumers import:

- `Rime` — public librime headers plus the `Rime` module only. No binaries are downloaded and nothing is linked. Wrapper libraries should depend on this product.
- `RimeDynamic` — the dynamic framework XCFramework. Xcode links and embeds it automatically for targets that declare the product.
- `RimeDynamicStub` — a link-only handle for the dynamic framework. It ships no binaries and exposes no API; each platform carries a skeleton `RimeDynamic.framework` in the SDK style (the `tapi stubify` stub sits at the binary's position), and targets that declare the product get `-framework RimeDynamic` from the package's linker settings with no embedded framework copy. XPC services and app extensions use it to share the app's single embedded `RimeDynamic.framework` (see below).
- `RimeStatic` — the static XCFramework with librime dependencies merged into the archive. Linked automatically.
- `RimeSystem` — binds against a system-provided or user-replaced librime implementation via `pkg-config rime` flags without distributing any librime headers. It also declares the `Rime` module, so do not combine `RimeSystem` and `Rime` in the same package graph.

Wrapper libraries depend on `Rime` only. Terminal apps that use the binary artifacts depend on `Rime` plus exactly one of `RimeDynamic`/`RimeStatic` (linked automatically, or manually with `pkg-config rime` flags). Apps binding a system librime depend on `RimeSystem` alone — `RimeSystem` replaces `Rime` in the graph, never combines with it.

### Linking without embedding (XPC services and app extensions)

Xcode embeds the `RimeDynamic` product into every target that declares it and offers no "link only" switch. Extension-like targets should declare `RimeDynamicStub` instead of `RimeDynamic`; the target is then linked against the framework by name while nothing is embedded. Wire the loader to the app's embedded copy:

1. Declare `RimeDynamicStub` on the XPC/extension target (alongside `Rime` or a wrapper library that already provides it).
2. Put the skeleton framework directory on the framework search path for the matching SDK. The skeletons are generated and committed by the release pipeline per platform under `Sources/RimeDynamicStub` in the package checkout; for a macOS XPC:

   ```text
   FRAMEWORK_SEARCH_PATHS[sdk=macosx*] = $(BUILD_DIR)/../../SourcePackages/checkouts/librime-xcframework/Sources/RimeDynamicStub/macos
   ```

   Condition the path per SDK (`macosx*`/`iphoneos*`/`iphonesimulator*` selecting the `macos`/`ios`/`ios-simulator` skeleton) and do not use one recursive path over all platforms: the skeletons share the framework name, and the linker should only be offered the skeleton whose target triples match the platform being linked.

3. Point the runpath at the app's embedded copy. For a macOS XPC service four levels up reaches the app's `Frameworks` directory:

   ```text
   LD_RUNPATH_SEARCH_PATHS = @executable_path/../../../../Frameworks
   ```

The skeletons are generated with `tapi stubify` from the released dylibs by the release pipeline and committed with the release manifest — the repository carries no hand-made stubs — so a skeleton always matches the artifacts of its tag. A mismatched skeleton fails loudly — at link time if the skeleton is older than the framework, at launch if it is newer.

### Code coverage in app-host test graphs

When a scheme with code coverage enabled builds a test graph where an app host and a test bundle share a package product, Xcode builds that product as a dynamic framework. Objects of Clang targets are then compiled with `-fprofile-instr-generate -fcoverage-mapping`, and every translation unit — even an empty or data-only one — references `___llvm_profile_runtime`. The product framework link does not include the profile runtime, so `build-for-testing` fails with `Undefined symbols: ___llvm_profile_runtime`. This is an Xcode/SwiftPM integration gap for Clang targets under coverage, not something the package can neutralize: no translation unit content escapes instrumentation, and adding profile-runtime linkage to the headers target would violate its zero-linkage contract.

Scope the scheme's coverage targets to your own targets (uninstrumented package targets link cleanly) or disable coverage for the affected scheme; normal app and extension builds without coverage are unaffected.

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
