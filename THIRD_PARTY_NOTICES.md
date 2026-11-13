# Third-Party Notices

Copyright (C) 2026 dsh-apple contributors, for the code original to this project.
Licensed under the GNU General Public License, version 3.

This project is distributed under the GNU General Public License, version 3
(see `LICENSE`). It is not an independent work: it links an emulator core that
is itself GPL-3.0, so the whole app is GPL-3.0. The notices below record where
each third-party component came from and under which terms it is used.

Nothing here is a legal opinion. It is a statement of what was actually
shipped and where the corresponding source lives.

---

## 1. The app itself

| Component | Source | License |
|---|---|---|
| This app (the iOS shell, the boot bridge, the debug console, the build scripts) | this repository | **GPL-3.0** |

## 2. Emulator core — iSH ARM64

| Field | Value |
|---|---|
| Upstream fork | <https://github.com/OpenMinis/ish-arm64> |
| Pinned commit | see `ish/UPSTREAM.lock.json` |
| Base project | <https://github.com/ish-app/ish> |
| License | **GPL-3.0** (`LICENSES/ISH-LICENSE.md`) |
| Additional terms | **`LICENSES/ISH-LICENSE.IOS`** |

`LICENSES/ISH-LICENSE.md` also records that contributions after
`0e3a4144f93135c4fd618c8397d2cfd87194f69f` are additionally available under
GPLv2, so that the code can be linked with GPLv2-only projects.

`LICENSES/ISH-LICENSE.IOS` is an additional permission from the iSH copyright
holders. It is narrow, and quoting it exactly matters:

> "... we have committed not to pursue any license violation that results
> **solely** from the conflict between the GNU GPLv2 or v3 and the Apple App
> Store terms of service. In other words, **as long as you comply with the GPL
> in all other respects, including its requirements to provide users with
> source code and the text of the license**, we will not object to your
> distribution of the iSH app through the App Store."

What it does **not** cover: the source-offer obligation, shipping the license
text, the "state that you changed the files" notice, the in-app legal notices,
or the licenses of the guest userland (section 4 below).

### 2.1 Vendored sub-libraries of iSH

Upstream keeps these as git submodules. This repository checks them out at the
pinned commits recorded in `ish/UPSTREAM.lock.json`.

| Component | Upstream | License |
|---|---|---|
| libapps (hterm) | <https://github.com/ish-app/libapps>, commit `b8cacae35e5b11d64bb736a053921c16ca7faf9e` | BSD-3-Clause |
| libarchive | <https://github.com/libarchive/libarchive>, commit `fc6563f5130d8a7ee1fc27c0e55baef35119f26c` | BSD-2-Clause |
| Alpine aports metadata | <https://github.com/ish-app/aports> | metadata only, not compiled |

## 3. Host runtime — Node.js for iOS

| Field | Value |
|---|---|
| Distribution | nodejs-mobile, `heylogin` fork |
| Release | `v24.5.0-mobile` (`nodejs-mobile-v24.5.0-ios.zip`) |
| URL | <https://github.com/heylogin/nodejs-mobile/releases/download/v24.5.0-mobile/nodejs-mobile-v24.5.0-ios.zip> |
| SHA-256 of the archive | `b3c515c451ed45d3a58915efe426e3cb9ac7debb56f649ddd62d871d97b2da9e` |
| Bundled Node version | 24.5.0 (`include/node/node_version.h`) |
| **Actual license** | **MIT**, exactly as upstream Node.js. The `heylogin` fork does not relicense anything: its `LICENSE` file is the stock Node.js license text — the Node.js MIT grant, the Joyent MIT grant, and the bundled third-party notices (Acorn MIT, c-ares MIT, cjs-module-lexer MIT, ittapi BSD-3-Clause, amaro MIT, swc Apache-2.0, undici MIT, OpenSSL Apache-2.0, and so on). |
| Corresponding source | <https://github.com/heylogin/nodejs-mobile> (fork of <https://github.com/nodejs-mobile/nodejs-mobile>) |
| Modification notices | The prebuilt slices are used unmodified. No local patches are applied to Node or to V8. |

## 4. Guest userland — Alpine Linux

The app bundles an Alpine root filesystem that boots inside the emulator. Each
package in it is a **separate program** with its own copyright holder; they are
aggregated on one volume, not combined into one work. Each must be complied
with individually — "the app is GPL-3.0" does **not** substitute for that, and
must not be read as relicensing them.

| Field | Value |
|---|---|
| Distribution | Alpine Linux 3.21, aarch64 |
| Base image | `alpine-minirootfs-3.21.0-aarch64.tar.gz` |
| Base image URL | <https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz> |
| Recipe lookup (not a source archive) | Alpine aports, branch `3.21-stable`, at `https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.21-stable/<repo>/<package>` (the read-only GitHub mirror is `https://github.com/alpinelinux/aports/tree/3.21-stable/<repo>/<package>`) |
| Package metadata | `RootfsPackages.md` lists the 72 installed packages, exact `pkgver-pkgrel`, license expressions and source-package names recovered from the unchanged image's `/lib/apk/db/installed`. The database `c:` fields identify exact aports commits recorded in each source notice. |

### 4.1 The three runtimes added in step 24 — called out separately

Step 24 added a JavaScript runtime, a package manager and a Python interpreter to
the image. Each is a substantial, separately-licensed work, and two of them carry
license families this project had not shipped before, so they are stated here
rather than left to the generated list.

| Package | Version in the image | License | aports path | Upstream |
|---|---|---|---|---|
| `nodejs` (with `ada-libs`, `simdjson`, `simdutf`, `c-ares`, `nghttp2-libs`, `brotli-libs`) | `22.23.4-r0` | **MIT** (the bundled third-party components carry their own: Apache-2.0, MIT, BSD-3-Clause) | `main/nodejs` | <https://nodejs.org/> |
| `npm` | `10.9.1-r0` | **Artistic-2.0** | `community/npm` | <https://github.com/npm/cli> |
| `python3` (with `pyc`, `python3-pyc`, `python3-pycache-pyc0`, `mpdecimal`, `libffi`, `gdbm`, `sqlite-libs`, `xz-libs`, `libbz2`, `icu-libs`, `icu-data-en`) | `3.12.16-r0` | **PSF-2.0** (Python Software Foundation License 2.0) | `main/python3` | <https://www.python.org/> |

Two notes that matter for compliance rather than for the build:

* **`npm` is declared Artistic-2.0 in Alpine metadata.** The generated per-package
  license column, rather than this runtime summary, identifies the other license
  families, including any ISC and X11 entries. Artistic-2.0 is GPL-3.0-compatible
  (the FSF lists Artistic-2.0 as compatible), so the aggregate is unaffected, but
  the notice is not optional: the package is distributed inside the app.
* **`icu-libs` and `icu-data-en` arrive as a dependency of `nodejs`.** They are
  under the ICU license, a permissive MIT-style text, and `icu-data-en` is 25 MB
  of the image's growth on its own. `REPORT-24.md` §6 records that number, because
  a dependency pulled in by a runtime that does not run is the one cost in this
  step that buys nothing.

**`apk-tools` is NOT in the shipped image.** The build removes it after installing
the packages, so the guest cannot install anything at run time. It is therefore
absent from `RootfsPackages.md` by design; its GPL-2.0-only license is recorded
here only so a reader who diffs this file against an earlier image knows why the
package disappeared rather than assuming an omission.

| Field | Value |
|---|---|
| Package | `apk-tools` (removed before the image is packaged) |
| License | **GPL-2.0-only** |
| aports path | `main/apk-tools` — <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.21-stable/main/apk-tools> |
| Why removed | the image must not be able to grow itself on the device; `/lib/apk/db` stays, which is what `RootfsPackages.md` reads |

### 4.2 BusyBox — called out separately

**busybox is licensed GPL-2.0-only.** This is stated on its own because it is
the component most often buried under "various" in projects that ship an Alpine
rootfs, and because GPL-2.0-only is *incompatible* with GPL-3.0: the two can
only coexist as an aggregate, each honoured on its own terms. Relabelling
busybox as GPL-3.0 would be wrong in both directions.

| Field | Value |
|---|---|
| Package | `busybox` (and its applet package `ssl_client`, which is also GPL-2.0-only) |
| Version in the shipped image | see `RootfsPackages.md` |
| License | **GPL-2.0-only** |
| aports source path | `main/busybox` — <https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.21-stable/main/busybox> |
| Upstream | <https://busybox.net/> |
| Why it is in the image | Alpine's `/bin/*` utilities are BusyBox applets; nothing runs in the guest without it |
| Source-offer | GPLv2 §3(a): a distributor must provide the source of the exact package in their image. The aports recipe and upstream tarball for the recorded `pkgver-pkgrel` are the starting point; they are not kept in this repository. |

Every package that ends up in the image is listed in `RootfsPackages.md`,
generated from the built image rather than from a plan. New builds include the
version, Alpine license expression and source-package name for every row.
The existing image's database was recovered without rebuilding it; its package
and version columns match the prior 72-entry list. The runtime and BusyBox
tables above are summaries, not license coverage for the whole image.

Supply each license and exception text in `LICENSES/rootfs/texts/` and the exact
source package's copyright and component notices in `LICENSES/rootfs/packages/`.
The collecting instructions and coverage limits are in `LICENSES/rootfs/README.md`.
The tree now contains 52 source-package/version notice files and 26 terms/exception
files. Source archives and local files were verified against exact aports recipes;
the notices include locked Rust crates and recovered npm dependency material.
Seven nested npm entries still lack a standalone exact-version full grant; their
original declarations/links and available notices are retained, without inventing
copyright lines. The presence check passes but does not resolve those limits.
The generator reports missing or empty files and still exports a development
image and draft table. `DSH_REQUIRE_NOTICES=1` makes missing
material fatal before export. These presence checks do not establish the
completeness of the recovered terms or replace a corresponding-source archive.

**The list describes one build.** Only the base image is pinned; `apk add` installs
whatever the Alpine 3.21 repositories offer that day, and a rebuild rewrites the
list. Versions quoted in this file can therefore differ from a fresh build.
Before distribution, retain the exact aports commits, APKBUILD files, patches
and upstream distfiles with checksums for the packages in that image, and supply
the corresponding-source archive with the matching build. The moving branch
links above are lookup starting points; they are not such an archive. Recording
an origin or a package version does not identify its repository or aports commit.
The archive for image `alpine-3.21.0-2e1ec684ab529225` (the image in 0.2.1 builds 21 and 22) is published at
<https://github.com/2570165831/dsh-apple/releases/tag/guest-sources-alpine-3.21.0-2e1ec684ab529225>.
A rebuilt image needs its own archive.

## 5. Reference and derived code

This app reuses designs, and in places code, from projects that solve the same
problems. They are listed because their licenses travel with what was copied.

| Project | Source | License | What was taken |
|---|---|---|---|
| deepseek-harness-ios | <https://github.com/liulingfei-1/deepseek-harness-ios> | **GPL-3.0** (its `LICENSE` is the GNU GPL v3 text verbatim, 675 lines) | The shape of the "lock commit + replayable patch series + build script" iSH packaging, and the eight-step boot order in its `Docs/ISH_SANDBOX_PORT.md` |
| dsh-ios | <https://github.com/everettjf/dsh-ios> | GPL-3.0 | The Alpine rootfs build approach (`scripts/build-rootfs.sh`): `fakefsify` the minirootfs, `apk add` inside the emulator, export with `unfakefsify`. Also the JS shims in `sim/` (the streaming `fetch` polyfill for a jitless Node, the `TextDecoder` and `Intl` shims), which were written against that project's working versions |
| OpenMinis | <https://github.com/OpenMinis/OpenMinis> | GPL-3.0 | The granularity of the third-party notice table, and the `ISHKernel` / `ISHShellExecutor` interface names the boot bridge mirrors |
| deepseek-harness (DSH) | <https://github.com/deepseek-ai/deepseek-harness> | MIT (npm packages) | The web UI and agent loop this app hosts, shipped as `payload/node_modules/@deepseek-ai/dsh` |

All four are GPL-3.0-compatible with this project's own GPL-3.0 license, so
there is no conflict to resolve — but they are listed because attribution is
owed regardless of compatibility, and because GPL-3.0 §5(a) requires modified
files to say they were modified.

Because iSH is GPL-3.0 and is linked into the same binary, the whole app is
GPL-3.0. The MIT and BSD components above remain under their own licenses and
are compatible with that.

## 6. Bundled npm dependencies

`payload/node_modules` is checked into this private repository. Both direct
packages, `@deepseek-ai/dsh` and
`@deepseek-ai/dsh-experimental-agent-team-profile`, are pinned to `0.2.1-rc.5`.
The lock file has 686 dependency entries; the trimmed iOS payload contains 602
installed packages: 520 MIT, 51 Apache-2.0, 15 BSD-3-Clause, 10 ISC,
2 BSD-2-Clause, and one each of Python-2.0, Unlicense, 0BSD and
(MIT OR CC0-1.0). Counts include nested installed dependencies.

The rc.5 update adds `@deepseek-ai/dsh-client-ui-entry-customization` (MIT),
`@earendil-works/pi-schema@1.5.0` (MIT), and two nested copies of
`@smithy/node-http-handler@4.14.1` (Apache-2.0), and removes `typebox`.
The Smithy copies and entry-customization package carry root license texts.
`pi-schema` carries `LICENSES/typebox-LICENSE` for its copied format validators,
but no root license for its own work; the component text is retained, and the
package's MIT grant has now been supplied separately from its exact monorepo tag.

Twelve version-matched supplements have been recovered under `LICENSES/npm/`,
including the TypeBox component notice and inspector's bundled DevTools notices.
Each records verified npm integrity and an immutable upstream source revision.
Four packages declare MIT but publish no grant. `brotli@1.3.3`, `dfa@1.2.0`
and `fontkit@2.0.4` serve only the removed LibreOffice package and are no longer
shipped (see `payload/ios-pruning.json`). `proxy-agent-negotiate@1.1.0` ships;
by the project owner's decision its supplement reproduces the MIT grant of its
sibling `http-proxy-agent` at the same upstream revision (same repository and
author), with that provenance stated in the file.

The remaining 87 lock entries are not installed in the iOS payload: 70 optional
entries excluded by the host platform and 17 installed packages removed by the
iOS policy (including platform binaries and the nested `fflate` of the removed
LibreOffice package). The exact package and path exclusions are recorded in
`payload/ios-pruning.json` and replayed, recoverably, by
`scripts/prune-payload-ios.py`. This policy was checked against every omitted
file in the old tracked payload; it preserves source files needed by packages
such as Ajv and only globally omits declarations and source maps.

`payload/package-lock.json` records registry tarballs and integrity hashes;
all resolved URLs use `https://registry.npmjs.org/`. Local source changes and
the complete content-patch inventory are explained in `PATCHES.md`. The public
export's fetch script and `payload-build/payload.patch` are not present in this
private worktree and are not evidence of how this update was performed.

The pending inventory is also in `LICENSES/npm/README.md`. Supply each missing
package's complete upstream license, original copyright notices and any NOTICE
in `LICENSES/npm/<name>@<version>.txt`, retaining the slash in scoped names.
`python3 -B scripts/check-npm-licenses.py payload/node_modules LICENSES/npm`
checks actual installed packages and currently exits 1 for the four missing texts.
Its unit tests passing does not establish that the payload has complete notices.
The public fetch script warns by default and fails with `DSH_REQUIRE_NOTICES=1`;
app distribution checks also remain in effect.

## 6.1 What a built app includes, and what is still missing

The build copies `LICENSE`, this file, `RootfsPackages.md` and the entire
`LICENSES/` tree into the app. About and Licences (关于与许可), reached from the
debug menu with a two-finger long press, shows the three root files, both iSH
notices and any supplied npm or guest `.txt` notices.

The About screen and three root files were added in `ec86b85`; they are not
pending work. That debug-menu entry alone is not a claim that the legal notices
meet GPL §5(d). The four missing payload grants and the guest npm coverage limits remain
outstanding. The guest corresponding-source archive exists for image
`alpine-3.21.0-2e1ec684ab529225` only (see section 4). The
recovered files and passing presence checks do not establish distribution readiness.

Each app build rechecks npm notices, guest texts, the image/database hashes and
the displayed inventory. Default Debug builds warn on failure, including with
old images. Release configurations, install/archive actions and the explicit
`DSH_REQUIRE_NOTICES=1` build setting fail on missing or stale material.
Distribution builds must use that switch for payload fetching, image generation
and the app build. Passing checks does not verify legal completeness or implement
source distribution.

## 7. Apple frameworks

The app links Apple system frameworks (Foundation, WebKit, UIKit, ...). They
are part of the OS, not distributed with the app, and are covered by Apple's
terms rather than by any license here.
