# Rootfs license material

The existing 2026-11-01 image was inspected without rebuilding it. Its exact
`data/lib/apk/db/installed` member contains 72 installed packages, represented by
52 source-package/version notice files in `packages/`. The image has no files
under `/usr/share/licenses`. Its `/usr/lib/python3.12/LICENSE.txt` and npm retry
`License` are used as preferred shipped notices and are byte-identical to their exact source
archive copies. Other material was recovered from source.

Every package's installed `c:` field identifies an immutable Alpine aports
commit. The exact main/community APKBUILD was recovered at that commit, and
upstream archives were downloaded from Alpine's v3.21 distfile mirror and
verified against that recipe's SHA-512 checksums. Each package notice records
the recipe URL/hash, aports commit, source archive URL/hashes and Alpine-local
source URLs/hashes. It preserves full upstream license/copyright/author files
and original source copyright/license comment blocks. Identical blocks are
printed once with all source paths. Collections can include build/test material
beyond the shipped subset; they do not assert that all such components ship.

`texts/` contains 26 recovered identifier/exception documents, including every
identifier in the actual Alpine expressions, the GCC runtime exception and
additional CC0/CC-BY terms used by npm's data dependencies. Identifier spelling
matches Alpine metadata, including `ICU`, `X11`, `Zlib`, `blessing`,
`bzip2-1.0.6` and `Public-Domain`. License/exception texts come from verified
package sources; MPL-2.0 and the two Creative Commons texts come from the pinned
SPDX license-list-data v3.27.0 commit. The XZ public-domain discussion is retained
verbatim, not rewritten as a new grant. The copyright lines in a shared terms
file apply to that upstream work; each package's own notices are separate.

The ripgrep notice also contains every registry crate's notices from its exact
Cargo.lock (51 crates, including build/platform alternatives). Each crate archive
is verified against the lockfile checksum. npm's notice preserves its Artistic
license and the dependency licenses available in its published source, plus
additional exact-source metadata and notices for nine dependencies lacking
standalone license files in that tarball.

## Remaining coverage limits

Seven nested npm dependency/version entries still have no recovered standalone
full package grant in their exact publication or source revision:
`@npmcli/agent@2.2.2`, `@npmcli/agent@3.0.0`, `eastasianwidth@0.2.0`,
`err-code@2.0.3`, `is-cidr@5.1.0`, `spdx-exceptions@2.5.0` and
`spdx-license-ids@3.0.20`. Their original declarations, links and available
copyright/author notices are preserved in `packages/npm@10.9.1-r0.txt`, and
CC-BY-3.0/CC0-1.0 terms are provided separately. No missing copyright line or
package-specific grant was synthesized. These limits require review; passing
the rootfs presence check does not resolve them. The local handoff lists the
exact source revisions and evidence for each entry.

Alpine release data/public-key packaging provides no separate upstream
copyright/grant file in aports. The exact recipes and their original contributor
and license declarations are preserved, without inventing a copyright holder.

License texts are not corresponding source. For image `alpine-3.21.0-2e1ec684ab529225` the exact
recipes, patches and distfiles are published as one archive at
<https://github.com/2570165831/dsh-apple/releases/tag/guest-sources-alpine-3.21.0-2e1ec684ab529225>;
every file in it was checked against the SHA-512 checksums in its recipe. A
rebuilt image is a different build and needs its own archive before it is
distributed; the presence checks cannot establish completion of that obligation.

## Image binding and generation

`ROOTFS-INSTALLED.txt` was recovered directly from the existing archive, bounded
by `ROOTFS-INSTALLED-BEGIN`/`ROOTFS-INSTALLED-END`. `ROOTFS-NOTICES.sha256` binds
that capture and the unchanged image. The obsolete adjacent package list had 54
entries (including removed apk-tools); it has been replaced by the rendered
72-row table. RootfsPackages.md already named exactly those 72 package/versions;
it now gains the license and source-package columns from the recovered database.
The standard renderer's build-script heading is retained for byte-for-byte
comparison; the build script itself was not run during this recovery.

No image or version-string change was made. An old image can be accompanied by
an independently recovered, hash-bound capture; a rebuild is not required just
to obtain the missing sidecars.

## Collection and checking rules

- `texts/<identifier>.txt`: complete terms for every identifier and exception,
  including both alternatives of OR. Keep the spelling in Alpine metadata.
- `packages/<origin>@<version>.txt`: original copyright/component notices for
  that exact source package, including bundled components and NOTICE files.
  One source notice can cover several installed subpackages only after review.
- Record the immutable source revision and source URL/checksum in each notice.
  Do not substitute TODOs, invented copyright lines or generic package grants.

`rootfs-notices.py` parses the sentinel-bounded installed database, emits the
inventory and checks required nonempty notice paths. AND/OR/WITH are
case-insensitive; identifiers preserve spelling. Unsupported expressions and
custom licenses fail without an explicit reviewed mapping. The checker is a
presence check, not a determination of legal completeness.

The rootfs build warns and emits a draft inventory by default;
`DSH_REQUIRE_NOTICES=1` stops export on missing materials. Release,
install/archive and that explicit setting require matching image/database
hashes, matching displayed inventory and all required files. Debug warns.
