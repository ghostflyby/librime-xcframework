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
- Set up CMake and Ninja in CI with `lukka/get-cmake`.
- Set up vcpkg in CI with `lukka/run-vcpkg`.
- Keep the vcpkg `builtin-baseline` only in `vcpkg.json`. Do not duplicate it in workflow environment variables.
- Let Dependabot update the vcpkg baseline and GitHub Actions versions.
- Do not require consumers to link librime's internal third-party dependencies manually.

## Packaging

- Build `librime` as a static library.
- Use upstream's existing `BUILD_STATIC=ON` CMake path.
- Merge vcpkg static dependency archives into each per-architecture `librime.a`.
- Combine macOS arm64 and x86_64 archives into one universal macOS static library before creating the XCFramework.
- Export only the public C API headers and module shim.
- Release artifacts should include `librime.xcframework.zip` and `build-metadata.json`. Do not generate a separate `.sha256` file because GitHub Releases exposes an asset digest.
- Wrapper versions should use `<upstream-version>-pack.<packaging-revision>` so tags work naturally with SwiftPM version requirements.
- In release workflows, empty `upstream_ref` should resolve to the latest upstream release tag, and empty `packaging_version` should be inferred from the resolved upstream version plus `packaging_revision`.
- The release workflow should generate `Package.swift` with the release zip URL and `swift package compute-checksum`, commit it, and tag that commit before creating the GitHub Release.

## Review

- Use a subagent to explore large or complex codebase changes.
- Must use a subagent to review your changes, and review only changed files.
