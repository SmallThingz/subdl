# Vendored TUI dependencies

The Zig 0.17 migration uses official upstream sources and preserves their licenses.

- `libvaxis`: https://github.com/rockorager/libvaxis, commit `6fd944a27fb3d6f596e981076381a3131f2448b4` (`zig-0.17`). Its `build.zig.zon` redirects zigimg to the adjacent official-source copy instead of the fork pinned by that branch. License: `libvaxis/LICENSE`.
- `zigimg`: https://github.com/zigimg/zigimg, commit `fcdd0d28d6393c747b2091874ed180856ab0ab73`. Local compatibility edits update Zig type reflection, a repeated-array test fixture, and the minimum Zig version. License: `zigimg/LICENSE`.

Patched zigimg files: `src/Image.zig`, `src/PixelFormatConverter.zig`, `src/formats/jpeg/writer.zig`, `tests/formats/sgi_test.zig`, and `build.zig.zon`. The Zig 0.17 formatter is applied only to those modified Zig files; other retained upstream files are byte-for-byte copies. Only each package manifest's distribution paths are retained.

Keep changes limited to compiler compatibility. Replace these copies with immutable official upstream dependency pins once an equivalent Zig 0.17 dependency chain is available.
