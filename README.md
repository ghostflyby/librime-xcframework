# librime XCFramework

This repository packages upstream `librime` as a static macOS XCFramework for Xcode and SwiftPM consumers.

The wrapper repository owns build, packaging, and release automation only. Upstream source changes should remain in `patches/` or in a selectable upstream ref. The local reference source is expected at `../librime`; CI checks out source into `vendor/librime`.

## Source Input

The build scripts default to the first available source directory:

1. `UPSTREAM_SOURCE_DIR`, when set
2. `vendor/librime`
3. `../librime`

By default the scripts build the current upstream checkout or the ref passed in `UPSTREAM_REF`. CI is intended to checkout the real upstream repository and then use this wrapper repository's vcpkg manifest and triplets to provide dependencies.

The local `../librime` `vcpkg` branch is only a reference for dependency choices and CMake behavior. It is not assumed to exist in the real upstream repository.

## Local Build

Prerequisites:

- macOS with Xcode command line tools
- CMake and Ninja
- vcpkg, with `VCPKG_ROOT` pointing at the vcpkg checkout
- upstream `librime` source at `../librime` or `vendor/librime`

Build both macOS slices:

```bash
VCPKG_ROOT=/path/to/vcpkg scripts/build-all.sh
```

Build one slice:

```bash
VCPKG_ROOT=/path/to/vcpkg scripts/build-one-arch.sh arm64
VCPKG_ROOT=/path/to/vcpkg scripts/build-one-arch.sh x86_64
```

Package the XCFramework:

```bash
scripts/package-xcframework.sh
```

Outputs:

```text
out/
  macos-arm64/
    lib/librime.a
    include/
  macos-x86_64/
    lib/librime.a
    include/
dist/
  librime.xcframework/
  librime.xcframework.zip
  librime.xcframework.sha256
  build-metadata.json
```

## Build Strategy

- Build `librime` as a static library with `BUILD_SHARED_LIBS=OFF`.
- Build third-party dependencies through the wrapper repository's `vcpkg.json` and static macOS triplets.
- Use upstream's existing `BUILD_STATIC=ON` CMake path, so CI can build unmodified public upstream refs.
- Merge vcpkg dependency archives into the distributed `librime.a` with `libtool -static`, so consumers link a single archive.
- Export only the public C API headers plus `RimeShim.h` and `module.modulemap`.

## Versioning

Use wrapper versions in `VERSION`, for example:

```text
upstream-1.16.1+pack.1
```

`1.16.1` is the upstream librime version; `pack.1` is the wrapper packaging revision.
