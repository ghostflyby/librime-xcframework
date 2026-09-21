# Third-Party Notices

This repository packages upstream `librime` and its build dependencies into
macOS and iOS XCFramework release artifacts.

The wrapper scripts, manifests, and documentation in this repository are
licensed under the BSD 3-Clause License. See `LICENSE`.

Binary release artifacts include upstream `librime` and may include statically
linked third-party dependency code resolved by vcpkg. Keep these notices with
any redistributed binary artifacts.

Release assets include:

- `LICENSE.txt`: the license for this packaging wrapper.
- `THIRD_PARTY_NOTICES.md`: this overview, the upstream `librime` notice, and
  the notices for the Rime plugins merged into librime.
- `third-party-notices.zip`: full license texts for the bundled third-party
  dependencies (vcpkg ports under `vcpkg/`) and for the merged Rime plugins
  (under `plugins/`).

## Upstream librime

Upstream project: <https://github.com/rime/librime>

License: BSD 3-Clause License

```text
Copyright (c) 2014, RIME Developers
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of the copyright holder nor the names of its
    contributors may be used to endorse or promote products derived
    from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Merged Rime plugins

The binary artifacts statically merge the Rime plugins listed below into
librime itself (`BUILD_MERGED_PLUGINS=ON`, `ENABLE_EXTERNAL_PLUGINS=OFF`). The
pinned revisions are recorded in `plugins.json` and in the release
`build-metadata.json`; full license texts are collected into
`third-party-notices.zip` under `plugins/`.

- **librime-lua** — Extending RIME with Lua scripts.
  Upstream project: <https://github.com/hchunhui/librime-lua>
  License: BSD 3-Clause License, Copyright (c) 2021, librime-lua Developers

- **librime-octagram** — RIME grammar plugin (八股文).
  Upstream project: <https://github.com/lotem/librime-octagram>
  License: BSD 3-Clause License, Copyright (c) 2014, RIME Developers
  Note: this plugin was distributed under GPLv3 until it was relicensed to
  BSD 3-Clause in July 2026. Pins older than that relicense must not be used,
  and the build verifies the BSD text is present before merging the plugin.

- **librime-predict** — RIME next-word prediction plugin.
  Upstream project: <https://github.com/rime/librime-predict>
  License: BSD 3-Clause License, Copyright (c) 2023, RIME Developers

### Bundled header-only libraries

Upstream `librime` compiles in two header-only libraries that are neither
vcpkg ports nor plugins. Their license texts are collected into
`third-party-notices.zip` under `librime/`.

- **darts-clone 0.32** (`include/darts.h`, double-array trie used by the
  dictionary prisms). Upstream: <https://github.com/s-yata/darts-clone>
  License: BSD 3-Clause (and LGPL 2.1 dual offer), Copyright (c) 2008-2013,
  Susumu Yata

- **utf8-cpp** (`include/utf8.h`, `include/utf8/*`, UTF-8 codec used by the
  dictionary and filter code). Upstream: <https://github.com/nemtrif/utfcpp>
  License: Boost Software License 1.0, Copyright 2006 Nemanja Trifunovic

### Lua runtime

`librime-lua` embeds a Lua interpreter. The artifacts do not use the plugin's
vendored `thirdparty` Lua checkout; the Lua C library is supplied by the vcpkg
`lua` port (Lua 5.5, MIT license, <https://www.lua.org/license.html>) so that
Apple platform patches and version pinning stay with the dependency manifest.
Its license text is collected into `third-party-notices.zip` under `vcpkg/`.
