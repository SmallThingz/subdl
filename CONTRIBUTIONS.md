# Contributions Guide

Thanks for contributing.

## Development Setup

Requirements:

- Zig `0.15.2+`
- Linux/macOS shell environment

Setup:

```bash
git clone <repo-url>
cd scrapers
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
4. Notes for provider-specific caveats (pagination, Cloudflare, captcha, etc.).

## Coding Expectations

- Keep provider logic isolated to provider modules.
- Add/maintain app-layer mapping in `providers_app.zig`.
- Avoid shelling out to external HTTP tools in runtime paths.
- Prefer explicit error handling and deterministic behavior.
- Keep user-facing strings and CLI/TUI flows clear.

## Testing

Run baseline tests before opening a PR:

```bash
zig build test
```

Run provider-targeted live tests when touching provider behavior:

```bash
zig build test-live-single -Dlive=extensive -Dlive-providers=subsource.net
```

Optional broader live checks:

```bash
zig build test-live -Dlive=smoke -Dlive-providers=* -Dlive-include-captcha=false
```

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

