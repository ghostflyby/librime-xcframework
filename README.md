# librime XCFramework

Static macOS XCFramework packaging for upstream `librime`.

This repository builds a binary distribution so Xcode and SwiftPM consumers do not need to compile librime and its C++ dependency graph themselves.

## Artifacts

A release contains:

- `librime.xcframework.zip`
- `librime.xcframework.sha256`
- `build-metadata.json`

The XCFramework contains a static macOS library with arm64 and x86_64 slices and the public librime C API headers.

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
upstream-<upstream-version>+pack.<packaging-revision>
```

Example:

```text
upstream-1.16.1+pack.1
```

