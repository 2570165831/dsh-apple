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
| Corresponding source | Alpine aports, branch `3.21-stable`, at `https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.21-stable/<repo>/<package>` (the read-only GitHub mirror is `https://github.com/alpinelinux/aports/tree/3.21-stable/<repo>/<package>`) |
| Package metadata | `RootfsPackages.md` in this repository records the exact `pkgver-pkgrel` of every package in the built image, read from `/lib/apk/db/installed` inside the guest |

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

* **`npm`'s Artistic-2.0 is the first non-copyleft, non-MIT-style license in this
  image** besides the ISC and X11 items already present. It is GPL-3.0-compatible
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

Every package that ends up in the image is listed with its version in
`RootfsPackages.md`, generated from the built image rather than from a plan.
Licenses are in the tables above and in each package's Alpine metadata.

**The list describes one build.** Only the base image is pinned; `apk add` installs
whatever the Alpine 3.21 repositories offer that day, and a rebuild rewrites the
list. Versions quoted in this file can therefore differ from a fresh build. Whoever
distributes a build must keep the corresponding source of the packages actually in
it: a moving branch of aports is not a guarantee that those recipes stay available.

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

`payload/node_modules` is rebuilt from npm by `scripts/fetch-payload.sh` and is not
kept in this repository. It contains 599 npm packages (519 MIT, 49 Apache-2.0, 15
BSD-3-Clause, 10 ISC, 2 BSD-2-Clause, and one each of Python-2.0, Unlicense,
0BSD and MIT-or-CC0-1.0), all transitively required by
`@deepseek-ai/dsh@0.2.1-rc.2`. Most packages ship a `LICENSE` file inside their directory
in `payload/node_modules/<name>/`, and those files are the authoritative notices
for them. These 15 only declare a license in `package.json`, so a distributor has
to supply the license text:

- `@aws-sdk/credential-provider-http@3.972.76 (Apache-2.0)`
- `@aws-sdk/credential-provider-login@3.972.81 (Apache-2.0)`
- `@aws-sdk/nested-clients@3.997.48 (Apache-2.0)`
- `@deepseek-ai/dsh-experimental-inspector@0.2.1-rc.2 (MIT)`
- `@earendil-works/pi-ai@1.3.0 (MIT)`
- `@earendil-works/pi-telemetry@1.3.0 (MIT)`
- `@xterm/addon-serialize@0.14.0 (MIT)`
- `@xterm/headless@6.0.0 (MIT)`
- `brotli@1.3.3 (MIT)`
- `data-uri-to-buffer@4.0.1 (MIT)`
- `dfa@1.2.0 (MIT)`
- `fontkit@2.0.4 (MIT)`
- `proxy-agent-negotiate@1.1.0 (MIT)`
- `saxes@6.0.0 (ISC)`
- `standardwebhooks@1.1.1 (MIT)`

Counted from the packages present after `scripts/fetch-payload.sh`: the lock file
has 84 more entries, which are not in the payload — 77 optional platform-specific
packages and the native-code packages iOS cannot load (`sharp`, `koffi`,
`node-pty`, `@vscode/ripgrep`, `sherpa-onnx-node`,
`@deepseek-ai/libreoffice-kit` and its bundled `fflate`). `payload/package-lock.json` pins the exact versions, which is what makes the
corresponding source obtainable. Changes to these packages are in
`payload-build/payload.patch` and explained in `PATCHES.md`.

## 6.1 What a built app does not include yet

The build does not copy `LICENSE`, this file or `LICENSES/` into the app, and the
app has no screen showing them. That has to be added before giving anyone a copy.

## 7. Apple frameworks

The app links Apple system frameworks (Foundation, WebKit, UIKit, ...). They
are part of the OS, not distributed with the app, and are covered by Apple's
terms rather than by any license here.
