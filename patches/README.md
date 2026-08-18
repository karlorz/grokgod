# grok-build Source Patches

This directory contains upstream source patches applied to `grok-build` for `grokgod`.

## Patches

- `0001-normalize-plugin-skill-join.patch`: Normalizes manifest path joins by filtering out `Component::CurDir` (`.`) components so relative paths like `"./skills/"` resolve identically to `"skills"`.

## Target Commit

- Base commit: `grok-build` commit `d71f6e0c` (`d71f6e0c330cfa9dc05273b06385cfcf6fb8dcf1`)

## Verification

To verify that a patch applies cleanly against the base commit:

```bash
git -C <grok-build-checkout> apply --check patches/0001-normalize-plugin-skill-join.patch
```

## Regeneration

To regenerate or update a patch:

1. Create a worktree of `grok-build` at base commit `d71f6e0c`:
   ```bash
   git -C /path/to/grok-build worktree add /tmp/grokbuild-patch-wt d71f6e0c
   ```
2. Apply changes and create the patch:
   ```bash
   git -C /tmp/grokbuild-patch-wt diff > patches/0001-normalize-plugin-skill-join.patch
   ```
3. Test applying in a clean verification worktree:
   ```bash
   git -C /tmp/grokbuild-verify-wt apply --check patches/0001-normalize-plugin-skill-join.patch
   ```

## Fail-Closed Policy

All patch applications must fail closed: if `git apply --check` or `git apply` exits with a non-zero status, build pipelines must halt immediately without building or distributing modified binaries.
