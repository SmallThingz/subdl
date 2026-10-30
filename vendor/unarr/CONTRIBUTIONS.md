# Contributing

## Development Setup

Requirements:

- Zig `0.17.0`
- standard C toolchain supported by Zig on your platform

Common commands:

```bash
zig build
zig build test
zig build check
```

## Contribution Workflow

1. Create a branch from `main`.
2. Make focused changes (one feature/fix per PR when practical).
3. Add or update tests for behavior changes.
4. Run validation commands locally.
5. Open a PR with context and verification notes.

## Pull Request Checklist

Before opening a PR, confirm:

- [ ] `zig build test` passes
- [ ] `zig build` passes
- [ ] public API changes are documented in `DOCUMENTATION.md`
- [ ] behavior changes are covered by tests
- [ ] commit messages clearly describe intent

## Coding Guidelines

- Prefer explicit error handling over silent fallthrough.
- Keep API behavior deterministic.
- Preserve ownership/lifetime semantics (`openStream` must not take stream ownership).
- Keep wrapper errors meaningful and bounded (`readAlloc(limit)`).
- Avoid introducing platform-specific behavior without clear guards.

## Documentation Expectations

If you change user-facing behavior, update:

- `README.md` (quick-start or surface-level behavior)
- `DOCUMENTATION.md` (API details and examples)

## Security Contributions

For security-sensitive issues, follow `SECURITY.md` rather than opening a public issue with exploit details.
