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

### Swift names

librime ships two API flavors and this package exports the `stdbool` one, so in C every affected type carries a `_stdbool` suffix (`RimeApi_stdbool`, `RimeMenu_stdbool`, …) and the entry point is `rime_get_api_stdbool`. That suffix is an artifact of flavor disambiguation and has no meaning to a Swift caller.

`Sources/RimeHeaders/include/Rime.apinotes` maps those names back, so Swift sees the plain spellings:

| Swift | C symbol it still calls |
|---|---|
| `RimeApi`, `RimeMenu`, `RimeContext`, `RimeStatus`, `RimeLeversApi` | the `_stdbool` structs |
| `rime_get_api` | `rime_get_api_stdbool` |

This is a **Swift-side breaking rename**: the suffixed spellings no longer resolve, and the compiler reports `has been renamed to …`. Existing call sites need the un-suffixed name (the fix-it suggests it); a signature that names `RimeApi_stdbool` explicitly needs a manual look.

Notes on the mechanism, because two failure modes are silent:

- API notes live outside the headers, so the annotations cannot be overwritten by the release pipeline's header sync — the file is installed alongside the headers and travels with the artifacts.
- A `Functions` entry must spell `SwiftName` with parentheses (`'rime_get_api()'`); without them the importer ignores the entry without a diagnostic. `scripts/verify-swift-names.sh` compiles a probe that fails if the plain names stop resolving, if the suffixed names still resolve, or if the two copies of the file drift apart. The release workflow runs it right after syncing headers.
- `RimeSystem` carries its own copy of the same file, since its headers come from a system librime rather than this repository; the probe keeps the two in sync.

### Linking without embedding (XPC services and app extensions)

Xcode embeds the `RimeDynamic` product into every target that declares it — directly or through a wrapper library — and offers no "link only" switch, so extension-like targets link through `RimeDynamicStub` instead: the target is linked against the framework by name while nothing is embedded. Wire the loader to the app's embedded copy:

1. Make sure the target links through the stub. A wrapper library that already carries the product needs nothing declared on the target — RimeKit does this through its `librimeDynamic` trait — and declaring `RimeDynamicStub` explicitly is only for targets that otherwise reach librime on their own.
2. Point the runpath at the app's embedded copy. For a macOS XPC service four levels up reaches the app's `Frameworks` directory:

   ```text
   LD_RUNPATH_SEARCH_PATHS = @executable_path/../../../../Frameworks
   ```

3. Add the skeleton directory to the framework search path **only when building that target on its own** (a scheme that compiles the extension without its host app):

   ```text
   FRAMEWORK_SEARCH_PATHS[sdk=macosx*]          = $(inherited) $(BUILD_DIR)/../../SourcePackages/checkouts/librime-xcframework/Sources/RimeDynamicStub/macos
   FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]        = $(inherited) $(BUILD_DIR)/../../SourcePackages/checkouts/librime-xcframework/Sources/RimeDynamicStub/ios
   FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) $(BUILD_DIR)/../../SourcePackages/checkouts/librime-xcframework/Sources/RimeDynamicStub/ios-simulator
   ```

   Condition the path per SDK rather than using one recursive path over all platforms: the skeletons share the framework name, and the linker should only be offered the skeleton whose target triples match the platform being linked.

   A full build does not need this. When the app target declares `RimeDynamic`, Xcode stages the real framework into `BUILT_PRODUCTS_DIR`, which is already on the framework search path and comes before the skeleton directory, so the extension resolves `-framework RimeDynamic` against the staged copy and the skeleton never comes into play. Building the extension alone stages nothing, so the search path is the only thing that can resolve the framework — and that failure is a link failure, not a runtime one; an extension cannot be launched without its host app either way.

The skeletons are generated with `tapi stubify` from the released dylibs by the release pipeline and committed with the release manifest — the repository carries no hand-made stubs — so a skeleton always matches the artifacts of its tag. A mismatched skeleton fails loudly — at link time if the skeleton is older than the framework, at launch if it is newer.

The stub travels as a source target rather than a `binaryTarget` because a binary target cannot express "link but do not embed": Xcode stages and embeds every binary target a bundle declares, and embedding reads the framework's binary. A source target produces no artifact to embed, which is what makes a text-based stub sufficient here — and is why the search path above is the one thing the package cannot supply by itself.

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
- upstream `librime` source at `../librime` or `vendor/librime` (`vendor/librime`
  may be a symlink to a development checkout; builds only read it)
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

Packaging also refreshes the sources this repository commits — the public
headers under `Sources/RimeHeaders/include` and the `RimeDynamicStub`
skeletons — so they always match the artifacts that were just produced.
`VCPKG_ROOT` is required (there is no in-repo vcpkg fallback) and `cmake` and
`ninja` must be on `PATH`.

Outputs are written to `out/` and `dist/`. Each slice also gets a `source.env`
recording the resolved upstream repo/ref/version/commit, which is what the
packaging job reads from the downloaded slices.

With no `UPSTREAM_REF`, the upstream **working tree** is built, so uncommitted
edits in a development checkout are what gets compiled; `UPSTREAM_REF` builds
that ref's committed content instead, and an unresolvable ref is an error. A
worktree build records `UPSTREAM_REF=worktree` and appends `-dirty` to the
commit when the tree is not clean, so the metadata does not overstate how
reproducible the build is.

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

The API is reachable as soon as the library is loaded — module registration runs
from a constructor — so install the sink **before** `rime->setup()` to also
capture the component-registration logging that `setup()` and `initialize()`
produce:

```c
traits.log_dir       = "";   // librime's own switch: never write log files
traits.min_log_level = 0;    // filtering here would also drop records from sinks
rime->setup(&traits);
api->set_stderr_threshold(RIME_LOGSINK_SILENT);   // after setup(), see below
api->add_sink(context, callback);
rime->initialize(&traits);
```

That combination yields no files, no stderr output, and every record in the
sink. Behaviour worth knowing:

- **Sinks are additive.** glog dispatches to every registered sink, so adding one
  does not replace another. Nothing is registered by default, and a host that
  does not ask for a sink sees unchanged logging.
- **File logging is controlled by librime, not by this API.** `traits.log_dir =
  ""` stops it, which is why there is no `disable_file_logging` here. It is
  one-way at the glog level: neither re-running `setup()` nor pointing
  `log_dir` somewhere else brings file logging back, so this API offers no
  counterpart that would only pretend to.
- **`log_dir = ""` also raises glog's stderr threshold to INFO** as a side
  effect, so set `set_stderr_threshold` *after* `setup()` or it gets
  overwritten. `SILENT` suppresses stderr entirely, fatal messages included.
  The threshold is process-wide because glog's is, so it affects the host's own
  glog usage too — and it is how you avoid duplicate records when your log
  system also collects stderr.
- Severity and threshold are separate enums: a record has a severity, an output
  has a threshold, and only the threshold can be `SILENT`. Swift sees both with
  their own case names — `RimeLogSinkSeverity.error`, `RimeLogSinkThreshold.error`
  — because Swift namespaces cases by type; C keeps the flat
  `RIME_LOGSINK_ERROR` / `RIME_LOGSINK_AT_ERROR` identifiers, where the `AT_`
  prefix is required by C's single namespace and reads as "at this level and
  above".
- The callback runs on the logging thread while glog holds a lock, may be called
  concurrently from several threads, and must return promptly. Do not call back
  into librime logging from it (that deadlocks).
- Records can contain user input (typed keys, dictionary entries). Redaction and
  retention are the callback's responsibility, not this module's.

One boundary worth stating: with the static artifacts the host's earliest
reliable call site is `main()`, because constructor order follows link order, so
anything logged before that is structurally uncapturable by an in-process sink.
That window is empty in current librime — its module constructors only register
and do not log — but it is a property of upstream, not a guarantee of this API.

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

Package versions are:

```text
<upstream-version>-pack.<epoch>.<minor>.<patch>
```

- **epoch** — the packaging era. Currently `9`, and a constant. It only exists
  to order above the earlier `<upstream-version>-pack.<N>` tags (the highest was
  `pack.8`); those tags are still valid and none of them had to be rewritten.
- **minor** — packaging changes worth distinguishing: a new capability, or a
  change consumers must react to.
- **patch** — another build of the same thing.

Only the **patch** is automatic. With `packaging_version` left empty the
workflow continues the current series, so a plain rebuild, or a rebuild after an
upstream patch release, never changes which packaging feature level a consumer
is being offered. Pass `packaging_version` explicitly to make a **minor** or
**epoch** release.

```text
1.17.0-pack.9.0.0     first package of 1.17.0 under this scheme
1.17.0-pack.9.0.1     rebuild, same feature level
1.17.0-pack.9.1.0     explicit packaging minor release
1.18.0-pack.9.0.0     upstream moved on; the epoch carries over
```

Releasing is ordered so that nothing becomes visible before everything else has
succeeded: the workflow commits the manifest and pushes the tag, creates the
release as a **draft** and uploads the assets, and only then flips it to
published and marks it latest as its final step. A failure anywhere before that
leaves a draft, not a half-announced release.

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
