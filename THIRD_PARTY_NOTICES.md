# Third-party notices

This file inventories third-party license and attribution material shipped with
this source tree and its installed artifacts. It does not grant a license to
this project, select an `only` or `or later` license version for it, or assert
that any binary distribution is compliant. The project owner must provide the
project-wide copyright and license grant before release.

## Installed layout

`zig build install` and `zig build build-all-targets` install this inventory as
`share/doc/scrapers/THIRD_PARTY_NOTICES.md` and vendor provenance as
`share/doc/scrapers/VENDOR_PROVENANCE.md`. License material is installed below
`share/licenses/scrapers/`:

- `LICENCE` and `COPYING` are the repository-supplied root texts. Their
  installation does not resolve the missing project-wide grant described
  above.
- `libvaxis/LICENSE` and `zigimg/LICENSE` are the retained upstream package
  licenses.
- `third-party/zhtml/LICENSE` is the retained zhtml license.
- `third-party/unarr/LGPL-3.0.txt` is the LGPLv3 text referenced by both the
  wrapper and native unarr packages, and `third-party/unarr/AUTHORS` preserves
  native unarr attribution and its public-domain exception inventory.
- `third-party/zigimg/HSLuv-MIT.zig.txt` preserves the license comment embedded
  in zigimg's HSLuv color implementation.
- `third-party/zig/Zig-MIT.txt` preserves the Zig-contributors MIT/Expat
  license for the identified standard-library-derived portions in libvaxis and
  zigimg.
- `third-party/uucode/` preserves uucode's main license and the notices it
  references for the UTF-8 decoder and generated Unicode data.

## Dependency provenance

### zhtml

The package is pinned from <https://github.com/SmallThingz/zhtml> at commit
`4130c7c348fd824df72d6096fc21b3e3c53b3bd5`, with Zig content hash
`html-0.1.0-dtdpOrY4MACjLqjVuKONnKlwVcQdPK4BxQ9EhmbaIQ06`. The pinned
package's `LICENSE` is retained verbatim as
`THIRD_PARTY_LICENSES/zhtml/LICENSE`, SHA-256
`57116ac0c4a678a845701176f4a55b1391e0393b1a516fdac169fe9709b24d67`.

### unarr wrapper and native unarr

The Zig wrapper is pinned from <https://github.com/SmallThingz/unarr.zig> at
commit `077de0c78813cf851556a8907911e531d63ac67d`, with Zig content hash
`unarr-0.0.0-9UpXA4QpAQB1NoRMmbz4ZFcJddLRcR0Fj5dvqCPoUaLd`. That wrapper pins
native <https://github.com/selmf/unarr> commit
`00799b5d6a7456eff37276ad376d1715ee222e02`, with Zig content hash
`N-V-__8AABWMCgDgDrwfEHLcf0rwMuWfSTEMZsTxuSs3oRJs`.

The wrapper's `LICENSE` and native package's `COPYING` are byte-identical CRLF
copies of the LGPLv3 supplemental text, each with source SHA-256
`ea7d049c7705dc13afc202dd18e1827f3484f8212fd3fa7b82fc4a0c363432c9`.
The single retained pointer target, `THIRD_PARTY_LICENSES/unarr/LGPL-3.0.txt`,
contains that text verbatim with line endings normalized to LF and has SHA-256
`da7eabb7bafdf7d3ae5e9f223aa5bdc1eece45ac569dc21b3b037520b4464768`.
Its references to GNU GPLv3 are accompanied in installed artifacts by the root
`COPYING`; that companion is the official FSF GPLv3 text with SHA-256
`3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.

Native unarr's `AUTHORS` is retained byte-for-byte, including its UTF-8 byte
order mark, as `THIRD_PARTY_LICENSES/unarr/AUTHORS`, SHA-256
`c48a43b79c6150a18369c9b9f10ae94bee61c7ad519b9f8f33014b2470bb9593`.
It identifies most code as LGPLv3 and records two exceptions: `common/crc32.c`
and `lzmasdk/*.*` as public domain, with their source URLs. Preserve this file
with any distribution containing native unarr.

### libvaxis, zigimg, and uucode

The vendored libvaxis and zigimg copies and their local changes are documented
in `vendor/README.md`. They derive from libvaxis commit
`6fd944a27fb3d6f596e981076381a3131f2448b4` and zigimg commit
`fcdd0d28d6393c747b2091874ed180856ab0ab73`. Their retained main license
files have SHA-256 values
`cca4ffa6a45c0b17d3e9840b4cbe5be1e76ab84fda69850e0cb3f117729eeeea`
and `57d0bd32e00043f6387cc7b86ed351f10c190a3d6266bbfa3fa21a1c3200e48f`,
respectively.

The exact 17-line HSLuv attribution and MIT notice from
`vendor/zigimg/src/color.zig` is retained verbatim, including comment prefixes,
as `THIRD_PARTY_LICENSES/zigimg/HSLuv-MIT.zig.txt`, SHA-256
`512f699123607215192e176594be7616cdded131d4b6b98e1a3796c08aa644ee`.
The standalone zigimg package retains a byte-identical mirror under
`vendor/zigimg/THIRD_PARTY_LICENSES/hsluv`; its default and `test-bin`
installs include that complete third-party tree.

Because the retained standalone libvaxis C libraries expose zigimg-backed
image-loading APIs, `vendor/libvaxis/THIRD_PARTY_LICENSES/zigimg` also contains
byte-identical copies of zigimg's main `LICENSE` and the retained HSLuv notice.
Their SHA-256 values are the same `57d0bd32e00043f6387cc7b86ed351f10c190a3d6266bbfa3fa21a1c3200e48f`
and `512f699123607215192e176594be7616cdded131d4b6b98e1a3796c08aa644ee`
listed above. The standalone libvaxis install includes its complete
`THIRD_PARTY_LICENSES` tree; these duplicate copies preserve the upstream
notices and do not grant a license to this project.

`vendor/zigimg/src/io.zig` identifies its `BitReader` and `BitWriter` as
imported from the Zig 0.14.1 standard library. The local libvaxis change in
`vendor/libvaxis/src/widgets/terminal/Command.zig` identifies its
`execvpeLinux` implementation as largely copied and adapted from Zig 0.17's
`std/Io/Threaded.zig`. The official
[Zig 0.14.1 license](https://github.com/ziglang/zig/blob/0.14.1/LICENSE) and
the exact license from the local Zig 0.17 compiler distribution are
byte-identical, SHA-256
`5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177`.
One exact copy is retained as `THIRD_PARTY_LICENSES/zig/Zig-MIT.txt` for both
identified portions. Standalone package mirrors are retained under
`vendor/zigimg/THIRD_PARTY_LICENSES/zig` and
`vendor/libvaxis/THIRD_PARTY_LICENSES/zig`; both package manifests include
those trees, and both standalone installs install them. This notice applies to
the identified Zig-derived portions and does not change the license of either
package or grant a license to this project.

Libvaxis pins uucode commit `1fb73433bba5d93366c57f23ff2e9d7939746500`
with Zig content hash
`uucode-0.2.0-ZZjBPm6FVgBcY-79AHV8ckQj86z0JwOyVyj89VeZrEiv`. Exact retained
copies are under `vendor/libvaxis/THIRD_PARTY_LICENSES/uucode`: `LICENSE.md`
has SHA-256
`312e901e142be2477b4ca859e9311f9e3f80d33372991759b7921c1893605f33`,
`licenses/LICENSE_Bjoern_Hoehrmann` has SHA-256
`de219cece932aad5a817bf763393d8d149d378a15d2ad5320e3331eac07626dd`,
and `licenses/LICENSE_unicode` has SHA-256
`1eda5a3b026870c737b22e8bcd4954338612c790db688242e003f41a4fa95175`.
The generated Unicode 16.0 letter/number range table in
`src/scrapers/unicode_letter_number.zig` is also derived from Unicode
Character Database general-category data and is covered by that retained
Unicode data license.

## Static-unarr release status

The default `-Denable-unarr=true` build statically links LGPLv3 unarr code.
Artifacts produced that way remain non-publishable from this repository until
the owner approves a project license grant compatible with the required
modification, relinking, and reverse-engineering permissions and the release
includes the exact corresponding source and application material, relinking
instructions, and installation information where applicable. Merely shipping
these notice files does not satisfy those requirements and is not a compliance
determination.
