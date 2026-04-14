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
- Export only the public C API headers and module shims. The static binary module is `RimeStatic`, the dynamic binary module is `RimeDynamic`, and the source `Rime` module re-exports one of them.
- Release artifacts should include `librime.xcframework.zip`, `librime-dynamic.xcframework.zip`, and `build-metadata.json`. Do not generate a separate `.sha256` file because GitHub Releases exposes an asset digest.
- Wrapper versions should use `<upstream-version>-pack.<packaging-revision>` so tags work naturally with SwiftPM version requirements.
- In release workflows, empty `upstream_ref` should resolve to the latest upstream release tag, and empty `packaging_version` should be inferred from the resolved upstream version plus `packaging_revision`. When `packaging_revision` is also empty, choose the next available pack revision for manual builds; scheduled upstream checks should skip publishing if any pack release already exists for that upstream version.
- The release workflow should generate `Package.swift` with direct `RimeStatic` and `RimeDynamic` binary products plus the `Rime` shim product using release zip URLs and `swift package compute-checksum`, commit it, and tag that commit before creating the GitHub Release.

## Review

- Use a subagent to explore large or complex codebase changes.
- Must use a subagent to review your changes, and review only changed files.
