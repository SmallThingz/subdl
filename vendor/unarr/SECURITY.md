# Security Policy

## Supported Versions

This project is currently pre-`1.0`.

| Version | Supported |
|---|---|
| `main` (latest commit) | ✅ |
| older commits/tags | ⚠️ best effort |

## Reporting a Vulnerability

Please do **not** open public issues for suspected vulnerabilities.

Preferred process:

1. Open a private security advisory in this repository (GitHub Security Advisories).
2. Include:
   - affected commit/tag
   - impact summary
   - reproduction steps or PoC
   - suggested fix (if available)
3. Wait for maintainer response before public disclosure.

If private advisories are unavailable, open a minimal public issue asking for a private contact channel, without posting exploit details.

## Scope

Security reports are especially relevant for:

- malformed archive handling that can trigger memory unsafety or crashes
- decompression/resource exhaustion vectors (CPU, memory, disk)
- path traversal or unsafe extraction patterns in consumer examples
- supply-chain concerns in dependency pinning/build fetch flow

## Response Expectations

Target (best effort):

- initial triage: within 7 days
- status update: within 14 days
- fix/release timing: depends on severity and reproducibility

## Coordinated Disclosure

Please allow time for patch development and validation before publishing technical details.
