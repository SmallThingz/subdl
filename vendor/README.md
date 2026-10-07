# Vendored TUI dependencies

The Zig 0.17 migration uses official upstream sources and preserves their licenses.

- `libvaxis`: https://github.com/rockorager/libvaxis, commit `6fd944a27fb3d6f596e981076381a3131f2448b4` (`zig-0.17`). License: `libvaxis/LICENSE`.
- `zigimg`: https://github.com/zigimg/zigimg, commit `fcdd0d28d6393c747b2091874ed180856ab0ab73`. Local edits cover Zig 0.17 type and I/O APIs, the minimum Zig version, an explicit `test-bin` step instead of installing the test binary by default, a repeated-array test fixture, portable TGA RLE byte packing, Zig 0.17 guide examples, validated raw-pixel ownership and editor bounds, and failure-safe image allocation and duplication. License: `zigimg/LICENSE`.

The zigimg correctness patches also roll back partial allocations for indexed
storage, PNG writer buffers, PAM comments, and TIFF tag data. TIFF tag parsing
also validates counts and types, decodes inline values, rejects short reads, and
checks palette, dimension, row, and strip metadata before allocation or decode.
The TGA RLE decoder retains its byte offset across short writes, including
writes ending partway through a pixel; an in-source regression exercises that
partial-write path.

The local libvaxis patch set covers `build.zig`, `build.zig.zon`, and the
retained runtime under `src/`. The build script maps the upstream
lazy-dependency call to Zig 0.17's `dependencyLazy` error-union API, removes
example and benchmark steps whose sources are not in this vendored subset,
installs the retained C libraries by default, and builds documentation from the
dependency-wired public module. The manifest redirects zigimg to the adjacent
official-source copy instead of the fork pinned by the branch, and updates
uucode to commit
`1fb73433bba5d93366c57f23ff2e9d7939746500` with content hash
`uucode-0.2.0-ZZjBPm6FVgBcY-79AHV8ckQj86z0JwOyVyj89VeZrEiv`.

That exact uucode package declares Zig 0.17.0 and includes `LICENSE.md` in its
published paths, but the main license links two files from an upstream
`licenses/` directory that the package manifest omits. Verbatim copies are
therefore retained in `libvaxis/THIRD_PARTY_LICENSES/uucode` and included in
libvaxis's distribution paths:

- `LICENSE.md` covers uucode itself (MIT, Copyright 2026 Jacob Sandlund),
  SHA-256 `312e901e142be2477b4ca859e9311f9e3f80d33372991759b7921c1893605f33`.
- `licenses/LICENSE_Bjoern_Hoehrmann` applies to `src/utf8.zig`, SHA-256
  `de219cece932aad5a817bf763393d8d149d378a15d2ad5320e3331eac07626dd`.
- `licenses/LICENSE_unicode` applies to `ucd/**` and generated Unicode data,
  SHA-256 `1eda5a3b026870c737b22e8bcd4954338612c790db688242e003f41a4fa95175`.

The standalone libvaxis C libraries also expose zigimg-backed image-loading
APIs. Exact copies of zigimg's main MIT license and embedded HSLuv MIT notice
are therefore retained under `libvaxis/THIRD_PARTY_LICENSES/zigimg`. They are
byte-identical to `zigimg/LICENSE` and
`../THIRD_PARTY_LICENSES/zigimg/HSLuv-MIT.zig.txt`, with SHA-256 values
`57d0bd32e00043f6387cc7b86ed351f10c190a3d6266bbfa3fa21a1c3200e48f` and
`512f699123607215192e176594be7616cdded131d4b6b98e1a3796c08aa644ee`,
respectively. The libvaxis manifest includes the complete
`THIRD_PARTY_LICENSES` tree, and its standalone install places that tree under
`share/licenses/vaxis/THIRD_PARTY_LICENSES`. These copies preserve upstream
notices; they do not supply a project-wide license grant.

The standalone zigimg package also retains a byte-identical HSLuv notice under
`zigimg/THIRD_PARTY_LICENSES/hsluv`. Its manifest includes that tree, and both
its default install and explicit `test-bin` install include the package's main
license and complete third-party tree.

Two retained portions also derive from the Zig standard library:
`zigimg/src/io.zig` identifies its `BitReader` and `BitWriter` as imported
from Zig 0.14.1, while the local
`libvaxis/src/widgets/terminal/Command.zig` change identifies
`execvpeLinux` as largely copied and adapted from Zig 0.17's
`std/Io/Threaded.zig`. The official
[Zig 0.14.1 license](https://github.com/ziglang/zig/blob/0.14.1/LICENSE) and
the exact license in the local Zig 0.17 compiler distribution are
byte-identical, SHA-256
`5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177`.
An exact copy is retained for standalone distribution in each affected
package under `THIRD_PARTY_LICENSES/zig/Zig-MIT.txt`. The zigimg manifest now
includes that tree and its default install places its own license and the tree
under `share/licenses/zigimg`; libvaxis already includes and installs its
complete third-party tree. This Zig notice applies only to the identified
Zig-derived portions and does not supply a project-wide grant.

These retained MIT and third-party notices are independent of the repository
root's `LICENCE` and `COPYING`. Root `COPYING` is present only as the verbatim
GPLv3 companion incorporated and referenced by the LGPLv3 supplemental text;
it does not apply GPLv3 to the vendored packages or choose project-wide license
terms.

Runtime patches adapt libvaxis to Zig 0.17 and harden lifecycle and ownership
behavior used by this project: terminal/signal coordination, Windows handle and
input-state handling, bounded lifetime-safe storage for queued key text,
transactional resize/render/mouse state, C API copying and bounds checks, vxfw
initialization and event state, and terminal child process cancellation and
cleanup. The affected runtime files are `src/GraphemeCache.zig`,
`src/Loop.zig`, `src/Parser.zig`, `src/Vaxis.zig`, `src/Window.zig`, `src/c_api.zig`,
`src/gwidth.zig`, `src/main.zig`, `src/tty.zig`, `src/unicode.zig`,
`src/vxfw/App.zig`, `src/vxfw/Border.zig`, `src/vxfw/RichText.zig`,
`src/vxfw/Text.zig`, `src/vxfw/TextField.zig`, `src/vxfw/vxfw.zig`,
`src/widgets/CodeView.zig`, `src/widgets/LineNumbers.zig`,
`src/widgets/TextInput.zig`, `src/widgets/terminal/Command.zig`,
`src/widgets/terminal/Screen.zig`, `src/widgets/TextView.zig`,
`src/widgets/terminal/Terminal.zig`, and `src/widgets/terminal/ansi.zig`.
The changes in `src/widgets/terminal/ansi.zig` make ANSI numeric-parameter
parsing reject arithmetic overflow; cursor-style handling ignores invalid or
overflowing CSI parameters instead of converting them into invalid enum values.
Focused in-source regressions cover both paths.

The Unicode tables retain both `is_emoji` and `is_emoji_vs_base`.
`src/gwidth.zig` applies VS15/VS16 presentation selectors only to an immediately
adjacent eligible emoji base; intervening combining marks break that adjacency.
Width sums saturate at the measurement type's limit, including `no_zwj` segments.
`cellWidth` clamps stored cell widths to 255 while callers retain full measured
widths for layout, avoiding narrowing traps on oversized graphemes.

Rendering fixes in `src/Window.zig`, `src/vxfw/RichText.zig` and
`src/widgets/TextView.zig` handle line endings, clipping and zero-width content.
Window and RichText recognize CR/LF/CRLF; RichText also handles CRLF split across
spans. Text and RichText advance past oversized graphemes during wrapping and
clip whole cell spans when drawing without wrapping. Border clips labels within
the inner right edge and handles zero/narrow bounds without alignment underflow.
CodeView preserves indentation during horizontal clipping and, with LineNumbers,
corrects highlight/padding behavior. TextField and TextInput use bounded cell
widths with Unicode cursor/drawing regressions across narrow viewports. Focused
regressions cover combining marks, CJK, ZWJ emoji, selectors, line endings,
scrolling, long labels and zero/narrow drawing bounds.

`TextView.Buffer.writer` uses Zig 0.17's `std.Io.Writer` internally while
retaining its value-style `write`, `writeAll`, and `print` conveniences and
their `error.OutOfMemory` contract. `stdWriter()` exposes the raw standard
interface, which reports `error.WriteFailed` as required; `lastError()` exposes
the underlying allocation failure.

On POSIX, the patched terminal widget's detached child reaper is the sole owner
of the spawned child's wait status until cleanup completes. Embedders must not
concurrently wait for that child, run a catch-all `waitpid(-1, ...)` reaper that
can consume it, or configure `SIGCHLD` as `SIG_IGN` or with `SA_NOCLDWAIT`.
`Terminal.spawn` rejects the two incompatible `SIGCHLD` policies; an external
waiter that steals the status violates the API contract and can prevent complete
process-group cleanup.

Patched zigimg files: `src/Image.zig`, `src/Image/Editor.zig`,
`src/Image/Managed.zig`,
`src/PixelFormatConverter.zig`, `src/color.zig`,
`src/compressions/deflate.zig`, `src/compressions/deflate/BlockWriter.zig`,
`src/formats/jpeg/writer.zig`, `src/formats/pam.zig`,
`src/formats/png.zig`, `src/formats/tga.zig`, `src/formats/tiff.zig`,
`src/formats/tiff/types.zig`,
`tests/color_test.zig`, `tests/image_editor_test.zig`, `tests/image_test.zig`,
`tests/formats/sgi_test.zig`, `tests/formats/tiff_test.zig`, `build.zig`,
`build.zig.zon`, and `README.md`. The Zig 0.17
formatter is applied only to modified Zig files. Files not listed here are
intended to track the retained upstream subset without intentional local source
changes; this maintenance record is not a byte-for-byte provenance attestation.
Only each package manifest's distribution paths are retained.

Keep local changes scoped to Zig compatibility and correctness, security, or
lifecycle fixes required by this project. Document every delta here, preserve
the upstream licenses, and prefer sending generally useful fixes upstream.
Replace these copies with immutable official upstream dependency pins once an
equivalent Zig 0.17 dependency chain contains the required fixes.
