# 0005: Generated installers, checked by drift guard

**Status:** accepted (2026-09-29)

The shipped installers (`install.sh`, `install.ps1`) and the Windows runtime
sources (`src/shim/grok-shim.sh`, `src/shim/templates/*.cmd.template`,
`src/shim/LauncherHelpers.ps1`) are compiled from `src/installer/` by
`src/installer/build.mjs` and are **no longer edited by hand**. The generated
files stay committed, so `git diff` and the release workflow keep working
unchanged; `build.mjs --check` fails when an artifact stops matching its
sources, and runs in CI before the test suites.

## What actually moved

Only the duplication that existed was extracted, and nothing else:

| Canonical source | Replaces |
| --- | --- |
| `shared/fast-forward-repo.sh` | the 123-line `fast_forward_or_reset_*` classifier, previously copied into `install.sh` and `src/shim/grok-shim.sh` (bodies were already byte-identical; only the function name differed, and the name is still injected per caller) |
| `shared/classify-signature.sh` | the 19-line `codesign -dv` classifier, previously copied into `install.sh` and `src/shim/grok-shim.sh` (same shape as fast-forward: one body, name injected per caller) |
| `shared/ps-engine-probe.cmd.part` | the 452-byte PowerShell engine probe, previously copied into two `.cmd` templates and `LauncherHelpers.ps1` |
| `constants.json` | `PINNED_BASE_SHA`, the repo slug, the Windows asset name, and the compat-daily issue title, each previously hardcoded in one or more artifacts |

Everything else — including the whole Windows transactional engine, the POSIX
disk guard, the release/source mode split, and every platform-specific branch —
moved verbatim into `templates/*.in`. The extraction is reversible: `cut.mjs`
re-derives each template from the committed artifact and refuses to write one
whose re-render is not byte-identical to the artifact it came from.

## Deliberate changes to shipped bytes

Regenerating is not bit-for-bit on the first commit, and that is the point:

- a `GENERATED FILE` banner is added to `install.sh` and `install.ps1`;
- the `Behavior must match the other copy ...` comments above the
  fast-forward and signature copies are deleted, because the build now makes
  the copies the same text and the warning would be false.

No executable line changed. `tests/install/test_install.sh`,
`tests/install/test_install_windows.py`, `tests/shim/test_shim_windows.py` and
`tests/release/test_release_workflow.sh` all pass against the regenerated
artifacts.

## Rejected alternatives

- **Deleting the generated artifacts and building them in CI.** Release assets
  are published from the committed files, and `install.sh` is fetched by URL;
  removing them from the tree changes the delivery contract for no benefit.
- **`<!-- generated -->` markers in a sidecar manifest instead of a build
  script.** A manifest records that a file was generated but gives no way to
  regenerate or verify it; the ClawGod-style template build gives both.
- **Extracting more (the `get_free_kb` helper, the launcher `.cmd` bodies).**
  `get_free_kb` is 14 lines shared with `src/grokgod-cache.sh`, which is a
  standalone runtime script rather than a build target — pulling it in would
  grow the pipeline for a helper that has not drifted. Same judgement for the
  `src/grokgod-*.sh` helpers.

## Consequences

- Renumbering or editing a shared block now means editing one file and running
  `node src/installer/build.mjs`; CI enforces that the run happened.
- `--check` treats "out of date" as a policy failure, so a hand edit to a
  generated installer is caught in review and in CI rather than surviving as a
  silent divergence between the two platforms.
- A template that fails to round-trip, an unresolved `{{GROKGOD:...}}`
  placeholder, a missing trailing newline, a CRLF, or non-ASCII in an
  ASCII-only target are all hard build errors.
