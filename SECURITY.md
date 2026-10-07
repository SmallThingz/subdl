# Security Policy

## Supported Versions

The package manifest is currently version `0.2.0` and requires Zig `0.17.0`.
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

The active providers `subsynchro.com`, `subs.sab.bz`, `animesub.info`, and
`fansubs.ru` currently serve the workflows used here only over plain HTTP. The
retained inactive `tvsubtitles.net` recovery path is also plain HTTP. Searches,
responses, and downloads can therefore be observed or modified in transit;
avoid these providers on untrusted networks. The AnimeSub implementation keeps
its short-lived cookie out of result tokens and sends it only to the provider's
exact route, but that restriction does not encrypt the network hop.

Treat `SUBSOURCE_CF_CLEARANCE`, its paired `SUBSOURCE_USER_AGENT`, the
`cloudflare_shared_sessions.json` cache, and any `SUBDL_WIZDOM_TMDB_API_KEY`
override as credentials. Do not share or commit them. Remove the cache to
invalidate saved browser sessions.

Treat `SCRAPERS_PRIJEVODI_COOKIE`, `SCRAPERS_PRIJEVODI_USER_AGENT`, and
`SCRAPERS_PRIJEVODI_FINGERPRINT` as a credential-bearing session bundle.
Use values from the same authorized browser after enabling the site's
download-protection consent. Never log or commit the values, issued download
tickets, or private browser/session artifacts. The adapter does not grant
consent, invent fingerprints, rotate identities, or bypass provider refusals.

Only complete a displayed provider challenge manually when you are authorized
to use that provider and session. Browser handoff does not solve CAPTCHAs or
bypass access controls; unresolved challenges and access blocks remain explicit
failures.

Filesystem publication assumes that the selected output directory and its parent
are not concurrently modified by an untrusted local process. The implementation
uses no-follow opens, exclusive atomic publication, randomized private staging
directories, and identity rechecks, but Zig 0.17's portable file metadata exposes
only a per-filesystem inode or FileIndex and does not provide conditional
rename/unlink operations by an open handle. These checks therefore do not form a
security boundary against a process that can mutate or mount within the output
path. Use an output directory that untrusted users cannot write. Administrator
and mount-namespace attacks, and validation of Windows DACL ownership, are
outside this guarantee.
