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

### Platform minimums

The artifacts target **iOS 15.0** and **macOS 11.0**. Those are not arbitrary: they are libc++'s minimum supported deployment targets, so building below them makes newer SDKs emit `"The selected platform is no longer supported by libc++."` That warning becomes an error in dependencies that compile with `-Werror` (leveldb does), which breaks the build rather than the consumer's. macOS 11.0 sits exactly on that line and needs no change; the iOS minimum is raised from 13.0, which predated it.

An app linking these artifacts needs a deployment target at least as high; linking an object built for a newer OS than the app targets warns, and the XCFrameworks carry the minimums above.

## Swift Package

Release tags contain a generated `Package.swift` with a headers target and binary targets that point at the matching GitHub Release assets.

```swift
.package(url: "https://github.com/ghostflyby/librime-xcframework.git", from: "1.16.1-pack.1")
```

All consumer source code writes `import Rime`. The `Rime` module is declared once, by product `Rime`'s headers target; the linking products below supply only the binary to link, not a module consumers import:

- `Rime` — public librime headers plus the `Rime` module only, shipped as a source-free systemLibrary: no binaries are downloaded, nothing is linked, and nothing is compiled on the consumer side. Wrapper libraries should depend on this product.
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

### Swapping the implementation (replaceable librime)

`RimeDynamicStub` fixes a contract, not an implementation. Declaring it emits `-framework RimeDynamic` — a load command for `@rpath/RimeDynamic.framework/Versions/A/RimeDynamic` plus a symbol requirement equal to the skeleton's exported list — and nothing else: whatever framework dyld resolves under that install name at runtime is the implementation. A wrapper library that links through the stub (directly, or through a package trait such as RimeKit's `librimeDynamic`) therefore leaves the choice of the librime binary to the final app:

1. **Released binary (default)** — declare `RimeDynamic` on the app target to embed the packaged framework.
2. **Custom or patched librime** — repackage the replacement under the same identity: bundle name `RimeDynamic.framework`, versioned layout `Versions/A/RimeDynamic`, install name `@rpath/RimeDynamic.framework/Versions/A/RimeDynamic` (set with `install_name_tool -id`; the replacement's own dependencies must remain resolvable). Embed and sign it in place of the packaged copy — the wrapper library needs no rebuild. The replacement's exported symbols must cover the skeleton's list of the tag the library was built against; a framework older than the skeleton fails at link time, a newer one fails at launch.
3. **System librime (e.g. Homebrew)** — a bare `librime.dylib` is not a drop-in for the stub: its install name differs. Either wrap it into the framework identity above, or use the `RimeSystem` product at the package-graph level (pkg-config), which replaces `Rime` and cannot coexist with it.

User data directories (`RimeTraits`) are independent of the binary: swapping the implementation does not touch deployed schemas or user configuration.

### Code coverage in app-host test graphs

Releases up to 1.17.0-pack.6 shipped the `Rime` headers product as a compiled Clang target. When a scheme with code coverage enabled built a test graph sharing that product between an app host and a test bundle, Xcode built the product as a dynamic framework whose link failed with `Undefined symbols: ___llvm_profile_runtime`: coverage instrumentation references the profile runtime from every translation unit (even empty or data-only ones), and the dynamic product framework link omits it.

The headers product now compiles nothing on the consumer side, so coverage builds are unaffected from the release that carries this change on. Since 1.17.0-pack.8 the `RimeDynamicStub` placeholder translation unit is Swift for the same reason: its product variant links the profile runtime through the Swift driver, while a C translation unit inside such a variant fails the same way. For older releases, scope the scheme's coverage targets to your own targets or disable coverage for the affected scheme; normal app and extension builds without coverage are unaffected.

The modules previously shipped as `RimeStatic`, `RimeDynamic`, and `RimeSystem`; import sites must change to `import Rime` starting with the first release built from this layout.

## Local Build

Prerequisites:

- macOS with Xcode command line tools
- CMake and Ninja
- vcpkg, with `VCPKG_ROOT` pointing at the vcpkg checkout
- upstream `librime` source at `../librime` or `vendor/librime`
- plugin submodules initialized: `git submodule update --init --recursive`

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

## Merged Plugins

The artifacts statically merge the Rime plugins that upstream ships in its own
release builds, so consumers get them without loading anything at runtime:

- `librime-lua` (module `lua`)
- `librime-octagram` (module `octagram`)
- `librime-predict` (module `predict`)

They also merge one plugin that belongs to this repository rather than upstream:

- `logsink` — forwards librime's diagnostics to host logging systems
  (`plugins/logsink`)

Plugins live in `plugins/`: the three upstream ones are git submodules pinned to
explicit commits, and `logsink` is a source directory of this repository (marked
`"local": true` in the manifest). `plugins.json` is the manifest the build
reads. `scripts/prepare-plugins.sh` copies each plugin into the upstream source
tree, applies the per-plugin patches listed in the manifest, and verifies the
license of every plugin that comes from outside this repository before merging
it.

`librime-lua` does not vendor its own Lua: the interpreter comes from the vcpkg
`lua` port, and the plugin is patched to use `find_package(Lua)` instead of
pkg-config. Keeping Lua in the dependency manifest means Apple platform patches
and version pinning stay with the other dependencies.

### Logging: the `logsink` plugin

librime logs through glog, whose symbols stay hidden inside the dynamic
framework — so a host cannot register a glog sink itself when it links
`RimeDynamic`. The `logsink` plugin is compiled into librime for exactly that
reason, and exposes a plain C callback instead (`rime_logsink_api.h`, shipped
with the other public headers):

```c
#include <rime_api.h>
#include <rime_logsink_api.h>

RimeModule* module = rime->find_module("logsink");
RimeLogSinkApi* sink = (RimeLogSinkApi*)module->get_api();
sink->add_sink(my_context, my_callback);   // every record, into your log system
```

The interface is deliberately destination-neutral: it hands you the record
(severity, message, source location, timestamp) and nothing else, so the host
decides what to write, where, and how much of it. A host that wants
`os.Logger` builds that on top of the callback in a few lines, with its own
subsystem, category and privacy choices.

Call it after `rime->setup()`/`initialize()`, which is where librime initializes
glog. Behaviour worth knowing:

- Sinks are **additive**. glog dispatches to every registered sink, so adding one
  does not replace another, and glog's own file and stderr logging keeps working
  unless you turn it off (`disable_file_logging`, `set_stderr_severity` — both
  process-wide, because glog's state is global; the latter is how you avoid
  ERROR records appearing twice when your log system also collects stderr).
- Nothing is registered by default: a host that does not ask for a sink gets the
  same logging behaviour as before.
- The callback runs on the logging thread while glog holds a lock, may be called
  concurrently from several threads, and must return promptly. Do not call back
  into librime logging from it (that deadlocks).
- Records can contain user input (typed keys, dictionary entries). Redaction and
  retention are the callback's responsibility, not this module's.

Two upstream behaviors matter for this arrangement:

- Static linking needs help. Module registration happens in static
  initializers, and a static linker drops those object files unless something
  references them. `patches/0001-static-plugin-module-references.patch` brings
  in upstream's fix for exactly this (upstream commit `cbf363be`, which landed
  after the `1.17.0` tag), so plugin modules are force-referenced by
  `rime_declare_module_dependencies()`.
- Plugin upgrades change candidate behavior, and `librime-octagram` was
  distributed under GPLv3 until it was relicensed to BSD 3-Clause in July 2026.
  Pins are therefore explicit, Dependabot proposals are reviewed rather than
  auto-merged, and the build refuses a plugin whose license text is not the
  expected one.

Plugin revisions are recorded in the release `build-metadata.json`, and license
texts are collected into `third-party-notices.zip` under `plugins/`.

The build merges the plugin modules and their runtime dependencies, but not
plugin *data* or tools: the `octagram` and `predict` modules ship without a
grammar/prediction database, and the plugin data generators are not built
(`BUILD_TOOLS=OFF`). Deploy the matching data files with your schema, as you
would with any other Rime distribution.

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

### Build-only runs

The `build` workflow publishes by default: it commits the regenerated release
manifest, pushes a tag, and creates the GitHub Release. To validate a branch or
a release candidate without publishing anything, dispatch it with
`publish: false`:

```bash
gh workflow run build.yml --ref my-branch \
  -f upstream_ref=1.17.0 \
  -f publish=false
```

A build-only run compiles every slice, packages the XCFrameworks, writes
`build-metadata.json`, and uploads them as the run's `librime-xcframework`
artifact, then stops. It does not commit the manifest, tag, or create a
release. This is also the way to exercise the release pipeline against a change
to the packaging scripts, because the workflow has no `pull_request` trigger.

## License

The packaging wrapper code in this repository is licensed under the BSD
3-Clause License. Binary release artifacts include upstream `librime`, which is
also BSD 3-Clause licensed, and may include statically linked third-party
dependencies resolved by vcpkg.

Keep `LICENSE.txt`, `THIRD_PARTY_NOTICES.md`, and `third-party-notices.zip`
with redistributed binary artifacts.
