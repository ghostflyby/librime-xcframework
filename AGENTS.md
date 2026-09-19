# Repository Instructions

This repository is a packaging wrapper for upstream `librime`. Keep changes scoped to build, packaging, CI, release, and documentation work for the XCFramework distribution.

## Source Handling

- Do not vendor long-term upstream source changes into this repository.
- Keep upstream compatibility changes in `patches/*.patch` when they are needed.
- CI should checkout the real upstream repository into `vendor/librime` without submodules.
- Treat the local sibling `../librime` repository, including any local `vcpkg` branch, as reference material only. Do not assume those local branches exist upstream.
- Build scripts should resolve upstream source in this order: `UPSTREAM_SOURCE_DIR`, `vendor/librime`, then `../librime`.
- Build scripts should build the current upstream checkout by default, or `UPSTREAM_REF` when provided.

## Dependencies

- Use this repository's `vcpkg.json` and custom triplets for third-party dependencies.
- Use overlay ports in `ports/` when a third-party dependency needs packaging-only fixes for Apple targets.
- Set up CMake and Ninja in CI with `lukka/get-cmake`.
- Set up vcpkg in CI with `lukka/run-vcpkg`.
- Use vcpkg's `files` binary cache source with `actions/cache`; do not rely on the removed `x-gha` backend.
- Keep the vcpkg `builtin-baseline` only in `vcpkg.json`. Do not duplicate it in workflow environment variables.
- Let Dependabot update the vcpkg baseline and GitHub Actions versions.
- Do not require consumers to link librime's internal third-party dependencies manually.

## Packaging

- Build `librime` as static libraries and dynamic frameworks for macOS and iOS.
- Use upstream's existing `BUILD_STATIC=ON` CMake path.
- Merge vcpkg static dependency archives into each per-architecture `librime.a`.
- Combine macOS arm64 and x86_64 archives into one universal macOS static library before creating the XCFramework.
- Build iOS device arm64 and combine iOS simulator arm64 and x86_64 archives into a universal simulator static library before creating the static XCFramework.
- Package dynamic outputs as `RimeDynamic.framework` slices for macOS, iOS device, and iOS simulator before creating the dynamic XCFramework.
- Package the macOS dynamic slice as a versioned deep bundle (`Versions/A` with relative symlinks and a `Versions/A` install name); keep iOS slices flat.
- Expose a single Swift module named `Rime` from the `RimeHeaders` headers target under `Sources/RimeHeaders/include`; keep `RimeShim.h` and the pruned librime public headers committed there.
- Ship the static and dynamic XCFrameworks without module maps so the `Rime` module is provided only by the headers target; keep the public headers inside the artifacts.
- Keep `RimeSystem` implementation-neutral: it is a systemLibrary declaring `module Rime [system]`, uses `pkg-config rime` for flags, does not add a module-map `link` directive that would force one library name, and must not be combined with the `Rime` headers product in one graph.
- Generate `RimeDynamicStub` linker stubs from the released dynamic dylibs with `tapi stubify` and commit them under `Sources/RimeDynamicStub/<platform>` with the release manifest. The stub target exposes no API and contributes only the `-lRimeDynamic` linker setting so extension-like targets can link without embedding.
- Release artifacts should include `librime-static.xcframework.zip`, `librime-dynamic.xcframework.zip`, `LICENSE.txt`, `THIRD_PARTY_NOTICES.md`, `third-party-notices.zip`, and `build-metadata.json`. Do not generate a separate `.sha256` file because GitHub Releases exposes an asset digest.
- Keep the repository license and binary distribution notices in sync with the release assets. The wrapper uses BSD 3-Clause, upstream `librime` is BSD 3-Clause, and vcpkg dependency copyright files should be collected into `third-party-notices.zip`.
- Wrapper versions should use `<upstream-version>-pack.<packaging-revision>` so tags work naturally with SwiftPM version requirements.
- In release workflows, empty `upstream_ref` should resolve to the latest upstream release tag, and empty `packaging_version` should be inferred from the resolved upstream version plus `packaging_revision`. When `packaging_revision` is also empty, choose the next available pack revision for manual builds; scheduled upstream checks should skip publishing if any pack release already exists for that upstream version.
- The release workflow should generate `Package.swift` with direct `Rime`, `RimeStatic`, `RimeDynamic`, and `RimeSystem` products using release zip URLs and `swift package compute-checksum`, sync the `Sources/RimeHeaders` headers from the build outputs, commit both, and tag that commit before creating the GitHub Release.

## Review

- Use a subagent to explore large or complex codebase changes.
- Must use a subagent to review your changes, and review only changed files.
