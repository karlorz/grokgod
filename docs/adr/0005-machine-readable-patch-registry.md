# 0005: Machine-readable patch registry, not a parallel manifest

`patches/registry.tsv` is the single machine-readable list of source patches.
Each data row is `id<TAB>name<TAB>file`; `name` is the patch stem and doubles as
the `grok status` persist key. Metadata rows (`registry-version`, `base-sha`)
carry the authored/application pin, which must equal `PINNED_BASE_SHA` in
`install.sh` and the pin recorded in `patches/README.md`.

The shim's `grok status` persist block renders its numbered lines from this
file instead of sixteen hand-copied `echo` lines, resolving the registry from
`$GROKGOD_SRC/patches/` and falling back to `$GROKGOD_HOME/src/patches/`
(the release-install layout, where `install.sh` copies the registry beside the
patches and the curl fallback fetches it). An unusable registry — absent,
unreadable, or damaged — omits the numbered lines without failing status,
truncating the block, or printing a stale one.

`tests/patches/test_registry.sh` is the enforcement half. It fails closed on a
duplicate or out-of-order id, a gap in the sequence, a registry entry whose file
is absent/empty/not-a-diff/CRLF, a registry that drifts from the patch files on
disk, a base SHA that drifts from `install.sh`/`patches/README.md`, and an
`install.sh` that stopped shipping the registry. It then compares the shim's
actual `persist:` block against the registry (byte-for-byte, in order) across
both registry layouts, and covers unreadable, absent, and malformed registries.
The assertions are behavioural rather than textual, so a correct rewrite of the
printer passes while a mutation that drops the fallback, the duplicate guard, or
the install-time copy fails.

Rejected: a generated `patches.json` with a free-form description per patch
(the prose already lives in `patches/README.md`, and two hand-maintained prose
copies drift); deriving the registry from the directory listing alone (ids,
names, and order would be implicit again); per-patch runtime toggles and native
Rust feature gates (out of scope — patches are re-applied as a stack and the set
is all-or-nothing).

`patches/README.md` and `docs/patch-inventory.md` stay human-facing prose; the
registry is the machine contract. Nothing in the installer transaction path
reads the registry, so application order still comes from the shell glob over
`patches/*.patch` (which the test pins to registry order).
