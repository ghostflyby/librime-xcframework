# Repository Instructions

This repository is a packaging wrapper for upstream `librime`. Keep changes scoped to build, packaging, CI, release, and documentation work for the XCFramework distribution.

## Source Handling

- Do not vendor long-term upstream source changes into this repository.
- Keep upstream compatibility changes in `patches/*.patch` when they are needed.
- CI should checkout the real upstream repository into `vendor/librime` without submodules.
- The no-submodules rule is about not pulling in librime's vendored third-party dependency graph. It does not apply to the Rime plugins under `plugins/`, which are submodules pinned to explicit commits.
- Treat the local sibling `../librime` repository, including any local `vcpkg` branch, as reference material only. Do not assume those local branches exist upstream.
- Build scripts should resolve upstream source in this order: `UPSTREAM_SOURCE_DIR`, `vendor/librime`, then `../librime`. `vendor/librime` may be a symlink to a development checkout; builds must only read it (export to a work directory), never write into it.
- Build scripts should build the upstream working tree by default, or the committed content of `UPSTREAM_REF` when provided; an unresolvable `UPSTREAM_REF` must fail rather than fall back.

## Dependencies

- Use this repository's `vcpkg.json` and custom triplets for third-party dependencies.
- Use overlay ports in `ports/` when a third-party dependency needs packaging-only fixes for Apple targets.
- Set up CMake and Ninja in CI with `lukka/get-cmake`.
- Set up vcpkg in CI with `lukka/run-vcpkg`.
- Require `VCPKG_ROOT` from the environment; do not add a fallback that looks for a vcpkg checkout inside this repository, and do not clone vcpkg into it. A silent fallback hides a missing environment dependency and invites a repo-local checkout that then has to be maintained.
- Use vcpkg's `files` binary cache source with `actions/cache`; do not rely on the removed `x-gha` backend.
- Keep the vcpkg `builtin-baseline` only in `vcpkg.json`. Do not duplicate it in workflow environment variables.
- Keep the `overrides` entry that pins `lua` to 5.4.8. `librime-lua` targets Lua 5.4 — it vendors `lua5.4` and defines `LUA_COMPAT_5_3` only for that path — while the baseline resolves `lua` to 5.5.0, and Lua 5.5 makes the loop variable const, so a 5.5 interpreter refuses ordinary Rime Lua configs. The failure shows up at runtime as a broken Lua plugin, not at build time, so the pin must not be dropped or bumped without verifying the plugin against the new version.
- Let Dependabot update the vcpkg baseline and GitHub Actions versions.
- Do not require consumers to link librime's internal third-party dependencies manually.

## Packaging

- Build `librime` as static libraries and dynamic frameworks for macOS and iOS.
- Keep the deployment targets at or above libc++'s supported minimums (currently iOS 15.0, macOS 11.0). Newer SDKs warn below them, and that warning is fatal in dependencies that compile with `-Werror` such as leveldb.
- Use upstream's existing `BUILD_STATIC=ON` CMake path.
- Merge vcpkg static dependency archives into each per-architecture `librime.a`.
- Combine macOS arm64 and x86_64 archives into one universal macOS static library before creating the XCFramework.
- Build iOS device arm64 and combine iOS simulator arm64 and x86_64 archives into a universal simulator static library before creating the static XCFramework.
- Package dynamic outputs as `RimeDynamic.framework` slices for macOS, iOS device, and iOS simulator before creating the dynamic XCFramework.
- Package the macOS dynamic slice as a versioned deep bundle (`Versions/A` with relative symlinks and a `Versions/A` install name); keep iOS slices flat.
- Expose a single Swift module named `Rime` from the `RimeHeaders` systemLibrary target under `Sources/RimeHeaders/include`; keep `RimeShim.h` and the pruned librime public headers committed there, and keep the target free of compiled sources (no placeholder translation unit) so consumer-side coverage instrumentation has nothing to hook.
- Keep the Swift-facing names un-suffixed with `Rime.apinotes` (not `swift_name` attributes in the headers, which the release header sync would overwrite). The file must exist in both `Sources/RimeHeaders/include/` and `Sources/RimeSystem/`, stay identical, and be installed with the exported headers so it travels with the artifacts; `scripts/verify-swift-names.sh` guards all three.
- Generate `Rime.apinotes` with `scripts/sync-apinotes.sh` rather than editing it: the script collects every declaration the headers flavor (typedefs, struct tags, functions) from clang's AST and renders both copies, so a new flavored declaration cannot be left unannotated. Each name is renamed to its own spelling with the suffix removed — a struct tag must not be folded into its typedef's name, because Swift imports the pair as two names for one type and consumers may use either. Build slices render the notes from their own headers, and the packaging step refreshes the committed copies from the synced headers.
- Ship the static and dynamic XCFrameworks without module maps so the `Rime` module is provided only by the headers target; keep the public headers inside the artifacts.
- Keep `RimeSystem` implementation-neutral: it is a systemLibrary declaring `module Rime [system]`, uses `pkg-config rime` for flags, does not add a module-map `link` directive that would force one library name, and must not be combined with the `Rime` headers product in one graph.
- Generate `RimeDynamicStub` skeletons from the released dynamic dylibs with `tapi stubify` and ship them as `librime-stub.zip`: the tbd sits at the binary's position inside `RimeDynamic.framework` (deep `Versions/A` layout for macOS, flat for iOS) and carries the real framework's install name. Keep `Sources/RimeDynamicStub` as a source target whose only contribution is the `-framework RimeDynamic` linker setting; do not ship the stub as a binary target, because Xcode stages, embeds and signs binary targets into bundle products and those steps read the framework's binary.
- Release artifacts should include `librime-static.xcframework.zip`, `librime-dynamic.xcframework.zip`, `librime-stub.zip`, `LICENSE.txt`, `THIRD_PARTY_NOTICES.md`, `third-party-notices.zip`, and `build-metadata.json`. Do not generate a separate `.sha256` file because GitHub Releases exposes an asset digest.
- Keep the repository license and binary distribution notices in sync with the release assets. The wrapper uses BSD 3-Clause, upstream `librime` is BSD 3-Clause, and vcpkg dependency copyright files should be collected into `third-party-notices.zip`.
- Statically merge the Rime plugins carried in `plugins/` (git submodules whose revisions are the committed gitlinks described by `plugins.json`) into librime with `BUILD_MERGED_PLUGINS=ON` and `ENABLE_EXTERNAL_PLUGINS=OFF`; static builds must keep upstream's plugin module force-reference mechanism so the linker does not drop their registration objects.
- Supply `librime-lua`'s interpreter from the vcpkg `lua` port rather than its vendored `thirdparty` checkout, and collect the plugins' license texts into `third-party-notices.zip` under `plugins/`. Verify each plugin's license text before merging, because `librime-octagram` was GPLv3 before its 2026-07 relicense.
- Wrapper versions use `<upstream-version>-pack.<generation>.<minor>.<patch>`. Only the patch may be inferred automatically (by `scripts/resolve-packaging-version.sh`); minor and generation releases require an explicit `packaging_version`. The generation is zero for an upstream version with no releases yet, so a new upstream version starts at `pack.0.0.0`; only an upstream version that already has legacy `pack.<N>` tags starts higher, which is how `1.17.0` begins at `pack.9.0.0` above its published `pack.8` without rewriting a tag. Never let an automatic build change the generation or minor, because that would change what a consumer is offered without anyone deciding it.
- A release must be created as a draft with its assets uploaded, and only published and marked latest as the final step, so a failure in any earlier step cannot leave a half-announced release.
- In release workflows, empty `upstream_ref` should resolve to the latest upstream release tag, and empty `packaging_version` should be inferred from the tags already published for that upstream version. Scheduled upstream checks should skip publishing when any pack release already exists for the latest upstream version, counting both the legacy and current suffix forms.
- The release workflow should generate `Package.swift` with direct `Rime`, `RimeStatic`, `RimeDynamic`, and `RimeSystem` products using release zip URLs and `swift package compute-checksum`, sync the `Sources/RimeHeaders` headers from the build outputs, commit them together with the matching `Sources/RimeSystem/Rime.apinotes` copy, and tag that commit before creating the GitHub Release.
- The build workflow must keep a build-only mode (`publish: false`) that builds, packages, and uploads the distribution artifact but neither commits the release manifest nor creates a GitHub Release, so a branch or release candidate can be validated without publishing.

## Tests

- Run upstream librime's suite, and keep it running against the patched, plugin-merged source this repository builds from (`BUILD_TESTS=1 scripts/build-one-arch.sh macos-arm64`, the `test` job in `build.yml`). The point is to catch the packaging layer breaking librime itself; a suite run against an unpatched checkout would report nothing about this repository. `package` depends on that job, so a failing suite stops a release.
- Keep `gtest` behind the `tests` feature in `vcpkg.json`, and keep artifact builds free of `BUILD_TEST`. Enabling the feature installs gtest into the dependency set, and `collect_vcpkg_notices` globs every port's copyright file - so a slice built with the tests feature would ship gtest's license in `third-party-notices.zip` for an artifact that does not contain gtest. Test mode therefore configures its own tree (`.build/build-<platform>-test`) rather than adding a flag to a slice build.
- Behavioral tests link a shared librime and drive real input sessions (`tests/`, `scripts/test-*.sh`), because the build-time gates cannot cover behavior. `verify_merged_plugins` checks merged module symbols in the static archive (and only there); nothing checks a module's runtime behavior, so a page key landing in the wrong place - or a lost `"paging"` tag, which is silent - would ship unnoticed. Upstream's suite cannot cover this either: it has no `selector` tests at all.
- A test that asserts fallback behavior must assert on the outcome a wrong answer would produce, not on an index: a cleared composition and a page turn both report index 0, so an index-only check passes either way. Cross-check any state a plugin publishes against the state the engine actually holds.
- Behavioral tests need a macOS build tree for the host's architecture, so `BUILD_TESTS` refuses an iOS slice or a non-native arch rather than producing a binary the runner cannot execute.

## Review

- Use a subagent to explore large or complex codebase changes.
- Must use a subagent to review your changes, and review only changed files.
