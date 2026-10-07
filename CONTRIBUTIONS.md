# Contributions Guide

Thanks for contributing.

## Development Setup

Requirements:

- Zig `0.17.0`
- Linux/macOS shell environment

Setup:

```bash
git clone https://github.com/SmallThingz/subdl.git
cd subdl
zig build
zig build test
```

## Repository Layout

- `src/scrapers/`: provider implementations
- `src/app/providers_app.zig`: provider-agnostic app API
- `src/cmd/cli.zig`: CLI
- `src/cmd/tui.zig`: TUI
- `src/lib.zig`: public exports
- `build.zig`: binaries and test steps

## What to Include in PRs

1. Focused changes with clear scope.
2. Tests for behavior changes or bug fixes.
3. Updated docs when CLI flags/API behavior changes.
4. Notes for provider-specific caveats (pagination, Cloudflare, CAPTCHA, etc.).

## Coding Expectations

- Keep provider logic isolated to provider modules.
- Add/maintain app-layer mapping in `providers_app.zig`.
- Avoid shelling out to external HTTP tools in runtime paths.
- Prefer explicit error handling and deterministic behavior.
- Keep user-facing strings and CLI/TUI flows clear.
- Do not add CAPTCHA solvers or access-control bypasses. Manual testing is
  limited to challenges displayed to an authorized user in that user's session.
- Keep dependencies on immutable commit/content-hash pins, and preserve Zig
  `0.17.0` compatibility when updating them.

## Testing

Run baseline tests before opening a PR:

```bash
zig build test
```

The default test graph includes TUI behavior tests when TUI support is enabled. Run `zig build test-tui` for that focused suite.
The executable and test targets require threaded I/O, even with the TUI disabled:
HTTP request deadlines race a fetch against a timeout. Root builds reject
`-Dsingle-threaded=true` instead of producing an executable whose requests fail
with `ConcurrencyUnavailable`.
On native Linux the default test graph also runs an offline process-cleanup
contract for the live runner; install Bash 4.3 or newer, GNU `timeout`,
`flock`, `mkfifo`, and standard `tee`, `grep`, `sed`, and `mktemp` utilities. It executes success,
failure, and missing-marker cases; signal scenarios are deliberately not
executed, while generated trap and cleanup structure is checked statically.

Run provider-targeted live tests when touching provider behavior:

```bash
zig build test-live-single -Dlive=extensive -Dlive-providers=subsource.net
```

Optional broader live checks:

```bash
zig build test-live -Dlive=smoke '-Dlive-providers=*'
```

Live tests require a native Linux target, Bash 4.3 or newer, GNU `timeout`,
`flock`, `mkfifo`, and network access. They are not available on macOS even though deterministic
development and test workflows are supported there.

## Commit and PR Hygiene

- Use descriptive commit messages.
- Keep commits reviewable (avoid unrelated edits).
- Link issues when applicable.
- Include before/after behavior in PR description for scraper fixes.

## Reporting Bugs

When filing issues, include:

- provider ID
- query/input used
- expected vs actual behavior
- logs/errors
- whether issue reproduces in CLI, TUI, library, or all

