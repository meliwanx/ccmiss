# Third-party notices

ccmiss source is distributed under GPL-3.0-or-later; see [LICENSE](LICENSE).
The following components retain their upstream licenses. They do not imply
endorsement of ccmiss by their authors.

| Component | Version | License | Upstream |
| --- | --- | --- | --- |
| Node.js | 24.17.0 | MIT and bundled third-party licenses | [nodejs/node](https://github.com/nodejs/node/tree/v24.17.0) |
| Mihomo | 1.19.32 | GNU GPL version 3; see its license and source notices | [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo/tree/v1.19.32) |
| js-yaml | 4.1.0 | MIT | [nodeca/js-yaml](https://github.com/nodeca/js-yaml/tree/4.1.0) |

## Source repository

The repository vendors the js-yaml JavaScript distribution in
`Resources/js-yaml.cjs`, together with `Resources/js-yaml-LICENSE.txt`.
`Resources/node-LICENSE.txt` and `Resources/mihomo-LICENSE.txt` retain upstream
license texts for reference. Downloaded runtimes, archives, signed app bundles
and generated icons are build outputs, not checked-in source.

## Public dependency downloads

`Tools/dependencies.json` pins public release URLs and SHA-256 checksums.
`Tools/fetch-dependencies.sh` downloads and verifies the Apple Silicon macOS
Node.js archive, Mihomo release binary and matching Mihomo source archive into
the ignored `.deps/darwin-arm64` directory. It extracts licenses from those
verified upstream archives. It does not install or run either component.

Node.js checksums come from the [official release checksum file](https://nodejs.org/dist/v24.17.0/SHASUMS256.txt).
The Mihomo release archive checksum is published in the asset metadata of the
[official release](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.32).
The unmodified [Mihomo source archive](https://codeload.github.com/MetaCubeX/mihomo/tar.gz/refs/tags/v1.19.32)
is downloaded with a pinned checksum as well. Node.js source is available from
the [matching official source release](https://nodejs.org/dist/v24.17.0/node-v24.17.0.tar.gz).

## Built application distribution

The build copies Node.js, Mihomo, their full upstream license files, the js-yaml
license, this notice and ccmiss's license into the application resources. It also
includes `mihomo-source-v1.19.32.tar.gz` and the Mihomo provenance record beside
the core. Signing the upstream binary for macOS does not modify its source;
the helper pins the resulting signed binary digest and validates its signer.

If you redistribute a built app, retain all notices and provide the complete
corresponding source required by the applicable GPL terms, including your
modifications and build instructions. An upstream URL alone is not a substitute
for those distribution obligations. Check the upstream source and license for
its dependencies and the full terms. Node.js's bundled `LICENSE` contains its
third-party notices and must also remain with redistributed Node.js binaries.

## Product names

Claude, Claude Code, Anthropic, Cloudflare, Stripe, macOS and other product names
belong to their respective owners. ccmiss is an independent project, with no
affiliation, approval or official safety certification from these providers.
