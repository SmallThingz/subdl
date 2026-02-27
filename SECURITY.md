# Security Policy

## Supported Versions

Security fixes are applied to the latest code on the default branch.

Older snapshots, forks, and unmaintained branches are not guaranteed to receive security updates.

## Reporting a Vulnerability

If you discover a security issue:

1. Do not open a public issue with exploit details.
2. Report it privately through GitHub Security Advisories (preferred) or direct maintainer contact.
3. Include:
   - affected provider/module
   - reproduction steps
   - impact description
   - proof-of-concept data (minimal and safe)

## Response Process

- Acknowledgement target: within 72 hours
- Initial triage: severity + affected scope
- Fix plan: patch, tests, and release/update notes
- Coordinated disclosure after mitigation is available

## Scope Notes

This project performs network requests to third-party subtitle providers. Security considerations include:

- parser safety on untrusted HTML/JSON inputs
- archive/file handling from remote sources
- terminal output safety for untrusted strings
- secret/environment variable handling in local runtime

