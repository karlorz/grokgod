# 0006: POSIX artifact manifest is an install record, not a decision source

`grokgod status --json` needs an artifact hash to compare against the installed
binary, and `.source-version` cannot supply one: a release stamp records the
downloaded asset digest **before** the Darwin ad-hoc `codesign -s - --force`
step (install.sh), so it never equals the installed file's SHA-256; and a source
stamp records a git commit, not a file digest at all. Comparing the stamp SHA
against the live binary would report `corrupt` on every real macOS release
install and every source install.

`install.sh` therefore records `~/.grokgod/manifest.json` at the two existing
stamp commit points, holding the digest of the installed file computed **after**
codesign, plus `platform`, `mode`, `version`, `patchset`, `sourceSha`,
`assetSha256`, `signature`, `targetExe`, and `grokgodHome`. The stamp printf
lines stay byte-identical and `.source-version` remains authoritative for every
install/update decision — `install.sh` never reads the manifest back, so a
missing or corrupt manifest cannot break an install or a fast path.

The manifest is deliberately *not* the Windows `manifest.json` schema. It omits
`files`, `backups`, `binDir`, and `journal`: POSIX uninstall is
`rm -rf "$GROKGOD_HOME"` (nothing to restore), while `install.ps1 -Uninstall`
deletes `manifest.files` and overwrites targets from `manifest.backups`
(install.ps1:477-545) — a POSIX-shaped sibling carrying those arrays would be a
cross-tool hazard if it ever landed in a Windows home. It adds
`platform: "posix"` so each reader can positively reject the other platform's
file, and the shim only trusts a manifest that is object-shaped with exactly one
`formatVersion: 1`, exactly one `platform: "posix"`, and exactly one
`artifactSha256`. Anything else is reported as `manifestValid: false` with a
`manifestDetail` reason, and status falls back to stamp-only behavior exactly as
before this change.

The writer is best-effort (`log_warn`, never `exit 1`): under `set -eu` a
read-only or full `GROKGOD_HOME` must not fail an otherwise good install.

Rejected: comparing the stamp SHA to the installed file (false `corrupt` on
macOS releases and all source installs); adding a hashing step to the human
`status` path (visible output must stay byte-identical); reusing the Windows
schema wholesale (imports the `files`/`backups` uninstall hazard); letting
`install.sh` read the manifest (creates a second source of truth).

## Amendment (2026-10)

The torn-install fast path in `live_binary_matches_stamp` added after this ADR
compared the stamp SHA to the live binary SHA. Because Darwin ad-hoc
`codesign -s - --force` modifies the live Mach-O binary upon activation, the
live hash never equals the download asset hash in `.source-version`. This
caused an infinite macOS re-download loop on `grok update` even when already on
the latest release.

Narrow exception: `install.sh` may read `artifactSha256` from `manifest.json`
**only** to decide the release "already up to date" fast-path skip. If the
manifest is missing or unusable (corrupt, malformed, non-posix platform, or
lacking a valid 64-hex `artifactSha256`), `install.sh` falls back to comparing
the stamp SHA against the live binary (preserving legacy/script fixture behavior).

The stamp remains authoritative for `VERSION`, `PATCHSET`, `MODE`, and the
initial download asset checksum. A corrupt manifest cannot declare "already up
to date" on Darwin or skip a needed reinstall: parse failure triggers the stamp
fallback, which mismatches the codesigned live binary and forces a reinstall.

Still rejected: treating the stamp SHA as the live binary identity on Darwin.
