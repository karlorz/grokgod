#!/bin/sh
set -eu

# test_registry.sh: Validate the machine-readable source patch registry
# (patches/registry.tsv) and everything that must stay in sync with it.
#
# Contracts enforced:
#   1. Registry shape: metadata keys, unique ordered numeric IDs, tab columns.
#   2. Every registered patch file exists, is non-empty, and is a real
#      `git apply`-shaped diff for the id/name in the registry.
#   3. Registry order == alphabetical file order == apply order (0001..N).
#   4. Registry covers exactly the patch files present in patches/ (no extra,
#      no missing) and the metadata base SHA matches install.sh +
#      patches/README.md.
#   5. Metadata name equals the status key printed by the shim persist block,
#      and the shim status block is generated from the registry rather than
#      hand-maintained.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="$REPO_ROOT/patches/registry.tsv"
SHIM="$REPO_ROOT/src/shim/grok-shim.sh"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
PATCHES_README="$REPO_ROOT/patches/README.md"

# The checks below run under `python3 -` with bare asserts; PYTHONOPTIMIZE / -O
# would silently turn every one of them into a no-op.
unset PYTHONOPTIMIZE || true

echo "=== Running Source Patch Registry Tests ==="

for f in "$REGISTRY" "$SHIM" "$INSTALL_SCRIPT" "$PATCHES_README"; do
  [ -f "$f" ] || { echo "FAIL: missing required file: $f" >&2; exit 1; }
done

python3 - "$REPO_ROOT" "$REGISTRY" "$SHIM" "$INSTALL_SCRIPT" "$PATCHES_README" <<'PY'
import re
import sys
from pathlib import Path

if sys.flags.optimize:
    print("FAIL: python assertions are disabled (PYTHONOPTIMIZE/-O); re-run without it", file=sys.stderr)
    raise SystemExit(1)

repo_root = Path(sys.argv[1])
registry_path = Path(sys.argv[2])
shim_path = Path(sys.argv[3])
install_path = Path(sys.argv[4])
readme_path = Path(sys.argv[5])

def require(haystack: str, needle: str, message: str) -> None:
    if needle not in haystack:
        print(f"FAIL: {message}", file=sys.stderr)
        raise SystemExit(1)

# ---------------------------------------------------------------- parse
registry_bytes = registry_path.read_bytes()
assert b"\r" not in registry_bytes, (
    "registry must be LF-only (no CR bytes); a CRLF checkout would break the shim's "
    "tab parse and the .gitattributes eol=lf rule pins it"
)
raw_lines = registry_bytes.decode("utf-8").splitlines()
text = "\n".join(raw_lines)

data_lines = []
meta = {}
for lineno, line in enumerate(raw_lines, start=1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    cols = line.split("\t")
    if len(cols) == 2:
        key, value = cols
        assert key not in meta, f"duplicate metadata key {key!r} at {registry_path}:{lineno}"
        meta[key] = value
    elif len(cols) == 3:
        data_lines.append((lineno, cols))
    else:
        print(
            f"FAIL: {registry_path}:{lineno} must be either 'key<TAB>value' or "
            f"'id<TAB>name<TAB>file' (tab-separated), got {len(cols)} columns",
            file=sys.stderr,
        )
        raise SystemExit(1)

assert meta.get("registry-version") == "1", "registry-version must be 1"
assert meta.get("base-sha"), "base-sha metadata row is required"
print("PASS: registry parses as tab-separated metadata + data rows")

# ---------------------------------------------------------------- ids/names
ids, names, files = [], [], []
for lineno, (row_id, name, rel) in data_lines:
    assert re.fullmatch(r"[0-9]{4}", row_id), f"id must be 4 digits at {registry_path}:{lineno}: {row_id!r}"
    assert re.fullmatch(r"[0-9]{4}-[a-z0-9-]+", name), f"unexpected patch name at {registry_path}:{lineno}: {name!r}"
    assert name.startswith(f"{row_id}-"), f"name {name!r} must start with its id {row_id!r}"
    assert rel == f"patches/{name}.patch", f"file {rel!r} must be patches/{name}.patch"
    ids.append(row_id)
    names.append(name)
    files.append(rel)

assert ids, "registry must list at least one patch"
assert len(set(ids)) == len(ids), "registry ids must be unique"
assert len(set(names)) == len(names), "registry names must be unique"
assert len(set(files)) == len(files), "registry files must be unique"
assert ids == sorted(ids), "registry ids must be in ascending order"
for a, b in zip(ids, ids[1:]):
    assert int(b) == int(a) + 1, f"registry ids must be contiguous and ordered: {a} then {b}"
print(f"PASS: {len(ids)} unique ordered contiguous ids ({ids[0]}..{ids[-1]})")

# ---------------------------------------------------------------- files exist
for name, rel in zip(names, files):
    path = repo_root / rel
    assert path.is_file(), f"registered patch file missing: {rel}"
    body = path.read_bytes()
    assert body, f"registered patch file is empty: {rel}"
    assert not body.startswith(b"\n"), f"registered patch file starts with a blank line: {rel}"
    assert b"diff --git " in body, f"registered patch is not a git diff: {rel}"
    assert b"\r" not in body, f"registered patch contains CR bytes (must be LF-only): {rel}"
print("PASS: every registered patch file exists, is non-empty, LF-only, and is a git diff")

# ---------------------------------------------------------------- order
disk = sorted(p.name for p in (repo_root / "patches").glob("*.patch"))
registered = [f"{name}.patch" for name in names]
assert registered == disk, (
    "registry must cover exactly the patch files on disk in the same order\n"
    f"  registry: {registered}\n"
    f"  on disk:  {disk}"
)
print("PASS: registry order matches alphabetical apply order of patches/*.patch")

# ---------------------------------------------------------------- base sha
pin = re.search(r"^PINNED_BASE_SHA=([0-9a-f]{40})\s*$", install_path.read_text(), re.MULTILINE)
assert pin, "PINNED_BASE_SHA missing from install.sh"
assert re.fullmatch(r"[0-9a-f]{40}", meta["base-sha"]), "base-sha must be a full 40-char hex SHA"
assert meta["base-sha"] == pin.group(1), (
    f"registry base-sha ({meta['base-sha']}) must match install.sh PINNED_BASE_SHA ({pin.group(1)})"
)
assert meta["base-sha"] in readme_path.read_text(), "registry base-sha must appear in patches/README.md"
print("PASS: base-sha matches install.sh PINNED_BASE_SHA and patches/README.md")

# ---------------------------------------------------------------- shim status
# The shim must read the registry rather than carry a literal patch list, and
# install.sh must actually ship the registry to where the shim looks. Wiring is
# proven behaviourally in the section below; here we only pin the pieces that
# cannot be observed from `grok status` output.
shim = shim_path.read_text()
require(shim, "patches/registry.tsv", "shim must read the registry for the persist block")
for name in names:
    assert name not in shim, f"hardcoded persist line must be gone from shim: {name}"
print("PASS: shim contains no hardcoded patch persist lines")

install = install_path.read_text()
assert "patches/registry.tsv" in install, "install.sh must ship the patch registry"
assert (
    'cp "$SCRIPT_DIR/patches/registry.tsv" "$GROKGOD_HOME/src/patches/registry.tsv"' in install
), "install.sh must copy the registry beside the patches in the installed src tree"
assert (
    '"$RAW_BASE/patches/registry.tsv"' in install
), "install.sh curl fallback must fetch the registry from the release tag base URL"
assert (
    '${REPO_PATH}/main/patches/registry.tsv' in install
), "install.sh curl fallback must keep the raw main registry fallback URL"
print("PASS: install.sh ships the registry (src sync + curl fallback)")
PY

# ---------------------------------------------------------------- behaviour
# The shim must render the persist block from the registry, in registry order,
# for both registry layouts it can meet in the wild:
#   - a GROKGOD_SRC tree that carries the registry itself (source install), and
#   - a GROKGOD_SRC tree without one, where the registry exists only in the
#     installed ~/.grokgod/src copy (release install).
# An unusable registry must never truncate or fail `grok status`.
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

TEST_HOME="$TMP_DIR/home"
TEST_GROKGOD_HOME="$TEST_HOME/.grokgod"
TEST_GROKGOD_SRC="$TMP_DIR/grokgod_src"
mkdir -p "$TEST_GROKGOD_HOME/bin" "$TEST_GROKGOD_SRC/src" "$TEST_GROKGOD_SRC/patches"

printf '#!/bin/sh\nexit 0\n' > "$TEST_GROKGOD_HOME/bin/grok"
chmod +x "$TEST_GROKGOD_HOME/bin/grok"
printf 'SHA=fake\nPATCHSET=v1.0.3\nVERSION=v1.0.3\nMODE=source\n' > "$TEST_GROKGOD_HOME/.source-version"
touch "$TEST_GROKGOD_SRC/src/grokgod-run.sh"
cp "$REGISTRY" "$TEST_GROKGOD_SRC/patches/registry.tsv"

run_status() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$TEST_GROKGOD_HOME" \
  GROKGOD_SRC="${1:-$TEST_GROKGOD_SRC}" \
  GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" \
  GROKGOD_UPDATE_CHECK_DISABLE=1 \
  sh "$SHIM" status
}

# Registry patch count and the persist block the shim must print for a status.
COUNT="$(awk -F'\t' 'NF==3 && $1 ~ /^[0-9]{4}$/ {n++} END {print n+0}' "$REGISTRY")"
expected_block() {
  awk -F'\t' -v want="$1" 'NF==3 && $1 ~ /^[0-9]{4}$/ {print "  " $2 ": " want}' "$REGISTRY"
}
persist_block() {
  # The registered patch lines, in printed order, between `persist:` and the
  # first non-patch persist line.
  awk '/^persist:$/ {inblock=1; next} inblock && /^  [0-9][0-9][0-9][0-9]-/ {print; next} inblock {exit}'
}

check_block() {
  want="$1"
  out="$2"
  label="$3"
  got="$(printf '%s\n' "$out" | persist_block)"
  expect="$(expected_block "$want")"
  if [ "$got" != "$expect" ]; then
    echo "FAIL: $label persist block differs from the registry" >&2
    echo "--- expected ---" >&2
    printf '%s\n' "$expect" >&2
    echo "--- got ---" >&2
    printf '%s\n' "$got" >&2
    exit 1
  fi
}

# Layout 1: registry inside GROKGOD_SRC (source install), patches applied.
APPLIED_OUT="$(run_status)"
echo "$APPLIED_OUT" | grep -q "^persist:" || { echo "FAIL: status output missing persist header" >&2; exit 1; }
check_block applied "$APPLIED_OUT" "applied"
echo "$APPLIED_OUT" | grep -q "  overlay-pin: wrapper" || { echo "FAIL: overlay-pin line missing" >&2; exit 1; }
echo "PASS: shim renders all $COUNT registry lines as applied, in registry order"

# Layout 1b: same tree, no stamp -> every registered patch is missing.
rm -f "$TEST_GROKGOD_HOME/.source-version"
MISSING_OUT="$(run_status)"
check_block missing "$MISSING_OUT" "missing"
printf 'SHA=fake\nPATCHSET=v1.0.3\nVERSION=v1.0.3\nMODE=source\n' > "$TEST_GROKGOD_HOME/.source-version"
echo "PASS: shim renders all $COUNT registry lines as missing, in registry order"

# Layout 2: release install — no registry in GROKGOD_SRC, registry only in the
# installed ~/.grokgod/src copy. The fallback must still render every line.
mkdir -p "$TEST_GROKGOD_HOME/src/patches"
cp "$REGISTRY" "$TEST_GROKGOD_HOME/src/patches/registry.tsv"
rm -f "$TEST_GROKGOD_SRC/patches/registry.tsv"
FALLBACK_OUT="$(run_status "$TEST_GROKGOD_SRC")"
check_block applied "$FALLBACK_OUT" "home-src fallback"
echo "PASS: shim falls back to the installed ~/.grokgod/src registry copy"

# A registry that is present but unreadable must degrade to omitting the
# numbered lines without failing or truncating status.
chmod 000 "$TEST_GROKGOD_HOME/src/patches/registry.tsv"
if [ -r "$TEST_GROKGOD_HOME/src/patches/registry.tsv" ]; then
  echo "SKIP: running as a user that ignores mode 000; unreadable-registry case not exercised"
else
  set +e
  UNREADABLE_OUT="$(run_status "$TEST_GROKGOD_SRC" 2>/dev/null)"
  UNREADABLE_STATUS=$?
  set -eu
  [ "$UNREADABLE_STATUS" -eq 0 ] || { echo "FAIL: status exited $UNREADABLE_STATUS on an unreadable registry" >&2; exit 1; }
  if printf '%s\n' "$UNREADABLE_OUT" | grep -q "  ${FIRST_NAME:-}:"; then
    echo "FAIL: unreadable registry still rendered patch lines" >&2
    exit 1
  fi
  echo "$UNREADABLE_OUT" | grep -q "  overlay-pin:" || { echo "FAIL: unreadable registry truncated the persist block" >&2; exit 1; }
  echo "PASS: unreadable registry degrades without failing status"
fi
chmod 644 "$TEST_GROKGOD_HOME/src/patches/registry.tsv" 2>/dev/null || true

# No registry anywhere (older install): status must still succeed and must not
# print a stale or half-built patch list.
rm -f "$TEST_GROKGOD_HOME/src/patches/registry.tsv"
NO_REGISTRY_OUT="$(run_status "$TMP_DIR/no_such_src")"
echo "$NO_REGISTRY_OUT" | grep -q "^persist:" || { echo "FAIL: status missing persist header without registry" >&2; exit 1; }
if printf '%s\n' "$NO_REGISTRY_OUT" | persist_block | grep -q .; then
  echo "FAIL: status printed registry lines without a registry" >&2
  exit 1
fi
echo "$NO_REGISTRY_OUT" | grep -q "  overlay-pin:" || { echo "FAIL: non-registry persist lines must survive" >&2; exit 1; }
echo "PASS: shim status degrades cleanly when the registry is unavailable"

# A malformed registry (duplicate / wrong-width ids, junk rows) must not render
# duplicated or bogus patch lines.
mkdir -p "$TEST_GROKGOD_SRC/patches"
awk -F'\t' 'NF==3 && $1 ~ /^[0-9]{4}$/ {print}' "$REGISTRY" > "$TEST_GROKGOD_SRC/patches/registry.tsv"
awk -F'\t' 'NF==3 && $1 ~ /^[0-9]{4}$/ {print; exit}' "$REGISTRY" >> "$TEST_GROKGOD_SRC/patches/registry.tsv"
printf '7\tseven\ttruncated\n000x\tbad-id\tpatches/x.patch\n' >> "$TEST_GROKGOD_SRC/patches/registry.tsv"
MALFORMED_OUT="$(run_status)"
check_block applied "$MALFORMED_OUT" "malformed"
echo "PASS: duplicate and malformed registry rows do not duplicate persist lines"

echo "=== Source Patch Registry Tests Passed ==="
