# npm license supplements

The pinned rc.5 payload has 16 packages without a root license file. Twelve
version-matched supplements have been recovered; four remain missing. The
presence checker still exits 1. No missing grant or copyright line has been
reconstructed from a generic MIT template.

| Package | Version | Declared license | Supplement | Source revision |
|---|---|---|---|---|
| `@aws-sdk/credential-provider-http` | `3.972.82` | Apache-2.0 | recovered | `258c14447eefd8e028db1a50ab49aac8312c0af9` |
| `@aws-sdk/credential-provider-login` | `3.972.87` | Apache-2.0 | recovered | `258c14447eefd8e028db1a50ab49aac8312c0af9` |
| `@aws-sdk/nested-clients` | `3.997.54` | Apache-2.0 | recovered | `258c14447eefd8e028db1a50ab49aac8312c0af9` |
| `@deepseek-ai/dsh-experimental-inspector` | `0.2.1-rc.5` | MIT | recovered | `b830ec950faba0a46dda564be3e2d854afed94f1` |
| `@earendil-works/pi-ai` | `1.5.0` | MIT | recovered | `f9a26365568127461c47a07a37dcb42c140a3ac5` |
| `@earendil-works/pi-schema` | `1.5.0` | MIT | recovered | `f9a26365568127461c47a07a37dcb42c140a3ac5` |
| `@earendil-works/pi-telemetry` | `1.5.0` | MIT | recovered | `f9a26365568127461c47a07a37dcb42c140a3ac5` |
| `@xterm/addon-serialize` | `0.14.0` | MIT | recovered | `f447274f430fd22513f6adbf9862d19524471c04` |
| `@xterm/headless` | `6.0.0` | MIT | recovered | `f447274f430fd22513f6adbf9862d19524471c04` |
| `brotli` | `1.3.3` | MIT | removed from iOS payload | `e36051345f6d27a56e5f39ea70d2f789b8574046` |
| `data-uri-to-buffer` | `4.0.1` | MIT | recovered | `85cd8c854aefbf1bb636789d80364cfac8ea1583` |
| `dfa` | `1.2.0` | MIT | removed from iOS payload | `3f5e603e5082caedabefefdf53e8a6ca3111e966` |
| `fontkit` | `2.0.4` | MIT | removed from iOS payload | `fbf3b9ef21eebd219eb73e666faed573af0fba09` |
| `proxy-agent-negotiate` | `1.1.0` | MIT | sibling grant (owner decision) | `b7e5f7ccce1a3ac5b339cc4c587974e8989cbc16` |
| `saxes` | `6.0.0` | ISC | recovered | `211fa0ebec9b628affc09219199639887174bfc3` |
| `standardwebhooks` | `1.1.1` | MIT | recovered | `b4d2c14fc5b4ccff3ff271e3b087dff812254c59` |

Each recovered `<name>@<version>.txt` contains the full upstream license,
original copyright notices and applicable bundled notices, with the registry
tarball URL, verified npm integrity, source URL and immutable commit. Scoped
names retain their slash. The published tarball was inspected before the source
repository. npm gitHead, exact-version repository manifests or release tags
tie the source to the publication. For xterm/headless, the packaging script
copies the root 6.0.0 version into the headless manifest; its checked-in 5.5.0
manifest is a template, not the publication version.

`pi-schema` includes both the monorepo MIT grant and the exact published
`LICENSES/typebox-LICENSE`. The inspector supplement also preserves the
Chromium DevTools and nested third-party license files from its publication.

## Packages without a published grant

The exact published artifacts and the entire source trees at the revisions in
the table were checked for license files, README grants, copyright comments
and NOTICE material. Four packages declare MIT but publish no grant:

- `brotli@1.3.3`, `dfa@1.2.0`, `fontkit@2.0.4`: used only by
  `@deepseek-ai/libreoffice-kit`, which the iOS policy already removes. They
  are now listed in `payload/ios-pruning.json` too, so the iOS payload does not
  ship them and no supplement is needed.
- `proxy-agent-negotiate@1.1.0`: statically imported by `http-proxy-agent` and
  `https-proxy-agent`, so it ships. By the project owner's decision its
  supplement reproduces, verbatim, the MIT grant of the sibling package
  `packages/http-proxy-agent/LICENSE` at the same upstream revision (same
  repository, same author, same declared license). The file states that
  provenance; it is not a text upstream published for this package itself.
