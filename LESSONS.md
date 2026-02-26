# Lessons Learned

## SubDL API and Data Shape
- Prefer SubDL's Next.js JSON endpoint for search: `/_next/data/<buildId>/<lang>/search/<encoded-query>.json`.
- The search payload lives in `pageProps.list` (not `results`).
- `pageProps.list` includes `sd_id`, `slug`, and `subtitles_count`, which are enough to construct links and availability state.
- Building subtitle links from search should be deterministic: `/subtitle/<sd_id>/<slug>`.
- Build IDs can become stale; a one-time retry after refreshing `buildId` is necessary.

## Language Handling
- Search language must be validated against a project allowlist to avoid invalid locale requests.
- Accept both human-readable language names and language codes.
- Normalize codes case-insensitively and treat `_` and `-` equivalently.
- Keep a default search language (`en`) in scraper options so callers can override behavior safely.

## Subtitle Group Semantics
- Empty subtitle groups should be filtered by default in scraper responses.
- Make empty-group inclusion an explicit option for UIs that need full visibility.
- Parsing logic should centralize this behavior so movie/TV paths behave consistently.

## TUI UX and Navigation
- Use a true terminal cursor in input fields (`showCursor` + beam shape), not a printed cursor glyph.
- Cursor movement/editing must be UTF-8 codepoint aware for left/right/backspace/delete.
- Keep long operations inside the TUI and render "Fetching..." status screens instead of dropping back to shell output.
- `Esc` should move up one level in flow-based UIs; reserve direct jumps for explicit shortcuts (`Ctrl+C`).
- Global exits should be uniform (`Ctrl+D` everywhere; `Ctrl+C` exits only from query screen).
- `Space`/`b` as page down/up is useful and intuitive in long lists.

## Rendering and Memory Safety
- Do not render from short-lived stack formatting buffers if the renderer may use data after the call stack changes.
- For frequently redrawn detail panes, use stable per-frame scratch buffers owned by the caller.
- Keep cursor hidden on non-input screens to avoid visual artifacts.

## Error Handling
- Friendly, contextual errors improve TUI resilience more than raw error names alone.
- Avoid silently downgrading critical checks (for example, subtitle-availability checks) when correctness affects selection state.

## Testing and Verification
- Add behavior tests, not just option-presence tests (for example, empty-group filtering on/off).
- Add focused utility tests for risky helpers (language resolution, URL/path encoding, date formatting).
- Run `zig fmt`, `zig build`, and `zig build test` after each meaningful patch to catch regressions quickly.
