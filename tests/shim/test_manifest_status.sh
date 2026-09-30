#!/bin/sh
set -eu

# test_manifest_status.sh: POSIX artifact manifest + `status --json` parity.
# Requires NO root and does NOT touch the real ~/.grokgod or ~/.local/bin.
# Runs on macOS `sh` (bash --posix) and Linux `sh` (dash).

unset GROK_CONFIG_PATH GROK_CONFIG ORCA_WORKTREE_ID ORCA_WORKSPACE_ID || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM_SRC="$REPO_ROOT/src/shim/grok-shim.sh"
INSTALL_SRC="$REPO_ROOT/install.sh"

if [ ! -f "$SHIM_SRC" ]; then
  echo "FAIL: shim not found at $SHIM_SRC" >&2
  exit 1
fi

# JSON assertions are driven by python3 (the same dependency the Windows shim
# contract suite already has). Fail loudly rather than silently testing nothing.
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is required for the status --json assertions" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

TEST_HOME="$TMP_DIR/home"
GH="$TEST_HOME/.grokgod"
SRC="$TMP_DIR/grokgod_src"
mkdir -p "$GH/bin" "$TEST_HOME/.local/bin" "$SRC/src" "$SRC/patches"
# The persist block is rendered from the machine-readable registry, so the
# isolated src tree must carry one for the human and JSON inventories to match.
cp "$REPO_ROOT/patches/registry.tsv" "$SRC/patches/registry.tsv"

BIN="$GH/bin/grok"
cat << 'EOF' > "$BIN"
#!/bin/sh
echo "FAKE_BIN_CALLED"
EOF
chmod +x "$BIN"

STAMP="$GH/.source-version"
MANIFEST="$GH/manifest.json"
LAUNCHER="$TEST_HOME/.local/bin/grok"

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Run the shim with an isolated home. GROKGOD_UPDATE_CHECK_DISABLE keeps the
# detached release check out of the picture; status never triggers it anyway.
run_json() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$GH" \
  GROKGOD_SRC="$SRC" \
  GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" \
  GROKGOD_UPDATE_CHECK_DISABLE=1 \
  sh "$SHIM_SRC" "$@"
}

run_grok_as() {
  HOME="$TEST_HOME" \
  GROKGOD_HOME="$GH" \
  GROKGOD_SRC="$SRC" \
  GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" \
  GROKGOD_UPDATE_CHECK_DISABLE=1 \
  "$@"
}

json_valid() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
}

json_field() {
  # json_field <file> <key> -> prints the raw JSON value for a top-level key
  python3 - "$1" "$2" << 'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
print(doc[sys.argv[2]] if sys.argv[2] in doc else "<missing>")
PY
}

json_key_list() {
  python3 - "$1" << 'PY'
import json, sys
print(",".join(json.load(open(sys.argv[1])).keys()))
PY
}

# The README field list is the published contract. It also mentions enum
# values in backticks, so the check keeps only the tokens that are emitted
# keys and requires that ordered subsequence to match exactly — a new field
# documented out of order, or an emitted field missing from the docs, fails.
readme_field_list() {
  python3 - "$REPO_ROOT/README.md" "$1" << 'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
keys = set(sys.argv[2].split(","))
match = re.search(r"^Fields[^\n]*:(.*?)\n\n", text, re.S | re.M)
if not match:
    print("<no Fields paragraph>")
    sys.exit(0)
tokens = re.findall(r"`([A-Za-z][A-Za-z0-9]*)`", match.group(1))
print(",".join(t for t in tokens if t in keys))
PY
}

json_detail_contains() {
  python3 - "$1" "$2" << 'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
needle = sys.argv[2]
hit = any(needle in d for d in doc.get("healthDetails", []))
print("yes" if hit else "no")
PY
}

write_stamp() {
  printf '%s\n' "$1" > "$STAMP"
}

write_manifest() {
  # $1 artifactSha256, $2 mode, $3 sourceSha, $4 signature
  cat << EOF > "$MANIFEST"
{
  "formatVersion": 1,
  "platform": "posix",
  "installedAt": "2026-09-29T00:00:00Z",
  "installedAtEpoch": 1759104000,
  "mode": "$2",
  "version": "v1.2.3",
  "patchset": "v1.2.3",
  "sourceSha": "$3",
  "assetSha256": "$1",
  "artifactSha256": "$1",
  "signature": "$4",
  "targetExe": "$BIN",
  "grokgodHome": "$GH"
}
EOF
}

echo "=== Running POSIX Artifact Manifest / status --json Tests ==="
BIN_SHA="$(sha_of "$BIN")"

# ---------------------------------------------------------------------------
# Test 1: healthy JSON with a matching manifest
# ---------------------------------------------------------------------------
echo "Test 1: healthy JSON with matching manifest"
printf '# GROKGOD shim\n' > "$LAUNCHER"
write_stamp "SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=release"
# Probe the live classifier before creating the manifest, then record exactly
# what this platform observes. On Linux that value is intentionally
# `unsupported`; on Darwin it reflects the local codesign result.
T1_LIVE_JSON="$TMP_DIR/t1-live.json"
run_json status --json > "$T1_LIVE_JSON" 2>/dev/null || true
T1_SIGNATURE="$(json_field "$T1_LIVE_JSON" signature)"
case "$T1_SIGNATURE" in
  adhoc|signed|unsigned|unsupported) : ;;
  *) echo "FAIL: unexpected live signature '$T1_SIGNATURE'"; exit 1 ;;
esac
write_manifest "$BIN_SHA" release "$BIN_SHA" "$T1_SIGNATURE"

set +e
HOME="$TEST_HOME" GROKGOD_HOME="$GH" GROKGOD_SRC="$SRC" \
  GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" GROKGOD_UPDATE_CHECK_DISABLE=1 \
  sh "$SHIM_SRC" status --json > "$TMP_DIR/t1.json" 2> "$TMP_DIR/t1.err"
T1_STATUS=$?
set -eu

[ "$T1_STATUS" -eq 0 ] || { echo "FAIL: healthy status --json exit $T1_STATUS"; exit 1; }
[ ! -s "$TMP_DIR/t1.err" ] || { echo "FAIL: status --json wrote stderr: $(cat "$TMP_DIR/t1.err")"; exit 1; }
json_valid "$TMP_DIR/t1.json" || { echo "FAIL: status --json is not valid JSON"; cat "$TMP_DIR/t1.json"; exit 1; }

[ "$(json_field "$TMP_DIR/t1.json" health)" = "healthy" ] || { echo "FAIL: expected healthy"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" mode)" = "release" ] || { echo "FAIL: expected mode release"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" version)" = "v1.2.3" ] || { echo "FAIL: expected version v1.2.3"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" patchset)" = "v1.2.3" ] || { echo "FAIL: expected patchset v1.2.3"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" patchStatus)" = "applied" ] || { echo "FAIL: expected patchStatus applied"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" artifactSha256)" = "$BIN_SHA" ] || { echo "FAIL: artifactSha256 mismatch"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" computedSha256)" = "$BIN_SHA" ] || { echo "FAIL: computedSha256 mismatch"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" artifactHashMatchesRecord)" = "True" ] || { echo "FAIL: expected artifactHashMatchesRecord true"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" launcherIdentity)" = "grok-shim.sh" ] || { echo "FAIL: unexpected launcherIdentity"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" launcherOwnership)" = "shim" ] || { echo "FAIL: expected launcherOwnership shim"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" manifestExists)" = "True" ] || { echo "FAIL: expected manifestExists true"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" manifestValid)" = "True" ] || { echo "FAIL: expected manifestValid true"; exit 1; }
[ "$(json_field "$TMP_DIR/t1.json" patchedBinaryExists)" = "True" ] || { echo "FAIL: expected patchedBinaryExists true"; exit 1; }
# Pinned POSIX nulls: status never executes the target binary and there is no
# official-binary resolver outside Windows.
python3 - "$TMP_DIR/t1.json" << 'PY' || { echo "FAIL: POSIX null parity fields drifted"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["schemaVersion"] == 1, d["schemaVersion"]
assert d["patchedBinaryVersion"] is None, d["patchedBinaryVersion"]
assert d["officialBinaryPath"] is None, d["officialBinaryPath"]
assert d["officialBinaryExists"] is False, d["officialBinaryExists"]
assert d["officialBinaryVersion"] is None, d["officialBinaryVersion"]
assert d["hashAlgorithm"] == "sha256", d["hashAlgorithm"]
assert d["launcherPath"].endswith("/.local/bin/grok"), d["launcherPath"]
assert d["patchedBinaryPath"].endswith("/bin/grok"), d["patchedBinaryPath"]
assert d["installedAt"] == "2026-09-29T00:00:00Z", d["installedAt"]
assert d["healthDetails"] == [], d["healthDetails"]
assert len(d["persist"]) == 23, len(d["persist"])
assert d["persist"][0].startswith("0001-normalize-plugin-skill-join: applied"), d["persist"][0]
assert d["persist"][-4] == "overlay-pin: missing", d["persist"][-4]
assert d["persist"][-3] == "eval-home: missing", d["persist"][-3]
assert d["persist"][-2] == "weekly-pin: global-default", d["persist"][-2]
assert d["persist"][-1] == "orca-pin: absent", d["persist"][-1]
assert d["sourceDrift"] == "unknown", d["sourceDrift"]
assert d["sourceDriftInstalled"] is None, d["sourceDriftInstalled"]
assert d["sourceDriftUpstream"] is None, d["sourceDriftUpstream"]
PY
# persist entries follow the patch status they are derived from.
printf "SHA=$BIN_SHA\\nPATCHSET=\\nVERSION=v1.2.3\\nMODE=release\\n" > "$STAMP"
run_json status --json > "$TMP_DIR/t1b.json"
python3 - "$TMP_DIR/t1b.json" << 'PY' || { echo "FAIL: persist entries do not follow patchStatus"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["patchStatus"] == "missing", d["patchStatus"]
assert all(e.endswith(": missing") for e in d["persist"][:-4]), d["persist"][:-4]
PY
# overlay/eval/orca-pin entries reflect the filesystem, like the human report.
touch "$SRC/src/grokgod-run.sh" "$SRC/src/grokgod-eval.sh"
mkdir -p "$GH/pin"
printf 'x\n' > "$GH/pin/orca-pin.toml"
run_json status --json > "$TMP_DIR/t1c.json"
python3 - "$TMP_DIR/t1c.json" << 'PY' || { echo "FAIL: persist overlay entries do not follow the filesystem"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["persist"][-4] == "overlay-pin: wrapper", d["persist"][-4]
assert d["persist"][-3] == "eval-home: wrapper", d["persist"][-3]
assert d["persist"][-1] == "orca-pin: present, not applied", d["persist"][-1]
PY
rm -f "$SRC/src/grokgod-run.sh" "$SRC/src/grokgod-eval.sh" "$GH/pin/orca-pin.toml"
write_stamp "SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=release"
SIG_VALUE="$(json_field "$TMP_DIR/t1.json" signature)"
case "$SIG_VALUE" in
  adhoc|signed|unsigned|unsupported) : ;;
  *) echo "FAIL: unexpected signature value '$SIG_VALUE'"; exit 1 ;;
esac
# Independent probe: the classifier must agree with a direct codesign call on
# this host, so a stubbed classifier cannot pass as "unsupported".
EXPECTED_SIG="$(sh -c '
  if [ ! -e "$1" ]; then printf absent; exit 0; fi
  if [ "$(uname -s)" != "Darwin" ] || ! command -v codesign >/dev/null 2>&1; then printf unsupported; exit 0; fi
  out="$(codesign -dv "$1" 2>&1 || true)"
  case "$out" in
    *"code object is not signed at all"*) printf unsigned ;;
    *"Signature=adhoc"*) printf adhoc ;;
    *"Authority="*) printf signed ;;
    *) printf unknown ;;
  esac
' sh "$BIN")"
[ "$SIG_VALUE" = "$EXPECTED_SIG" ] || {
  echo "FAIL: signature '$SIG_VALUE' disagrees with a direct codesign probe '$EXPECTED_SIG'"; exit 1
}
python3 - "$TMP_DIR/t1.json" << 'PY' || { echo "FAIL: freeDisk fields are not numeric"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert isinstance(d["freeDiskBytes"], int), d["freeDiskBytes"]
assert isinstance(d["freeDiskGigabytes"], float), d["freeDiskGigabytes"]
PY
EXPECTED_KEYS="schemaVersion,health,healthDetails,mode,version,sourceSha,patchset,patchStatus,persist,launcherIdentity,resolvedCommandPath,launcherPath,launcherOwnership,patchedBinaryPath,patchedBinaryExists,patchedBinaryVersion,officialBinaryPath,officialBinaryExists,officialBinaryVersion,artifactSha256,computedSha256,hashAlgorithm,artifactHashMatchesRecord,signature,recordedSignature,signatureVerified,manifestPath,manifestExists,manifestValid,manifestDetail,installedAt,freeDiskBytes,freeDiskGigabytes,sourceDrift,sourceDriftInstalled,sourceDriftUpstream"
[ "$(json_key_list "$TMP_DIR/t1.json")" = "$EXPECTED_KEYS" ] || {
  echo "FAIL: JSON key set/order drifted"
  echo "  got:      $(json_key_list "$TMP_DIR/t1.json")"
  echo "  expected: $EXPECTED_KEYS"
  exit 1
}
# README documents the same key set, in the same order.
README_KEYS="$(readme_field_list "$EXPECTED_KEYS")"
[ "$README_KEYS" = "$EXPECTED_KEYS" ] || {
  echo "FAIL: README field list disagrees with the emitted key set"
  echo "  readme: $README_KEYS"
  echo "  emitted: $EXPECTED_KEYS"
  exit 1
}
echo "PASS: Test 1"

# ---------------------------------------------------------------------------
# Test 2: human-readable status is untouched by the JSON addition
# ---------------------------------------------------------------------------
echo "Test 2: human status output preserved"
HOME="$TEST_HOME" GROKGOD_HOME="$GH" GROKGOD_SRC="$SRC" \
  GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" GROKGOD_UPDATE_CHECK_DISABLE=1 \
  sh "$SHIM_SRC" status > "$TMP_DIR/t2.txt" 2> "$TMP_DIR/t2.err"
[ ! -s "$TMP_DIR/t2.err" ] || { echo "FAIL: human status wrote stderr"; exit 1; }
grep -q "^shim: " "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost 'shim:'"; exit 1; }
grep -q "^target binary: $BIN$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost target binary line"; exit 1; }
grep -q "^target binary exists: yes$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost exists line"; exit 1; }
grep -q "^source-version: SHA=$BIN_SHA$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost source-version blob"; exit 1; }
grep -q "^~/.local/bin/grok is grokgod shim: yes$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost launcher ownership line"; exit 1; }
grep -q "^free disk: " "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost free disk line"; exit 1; }
grep -q "^persist:$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost persist header"; exit 1; }
grep -q "^  0016-credit-limit-switch-model: applied$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost 0016 line"; exit 1; }
grep -q "^  0017-welcome-logo-chat-accent: applied$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost 0017 line"; exit 1; }
grep -q "^  0018-gemini-option-enum-null-schema: applied$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost 0018 line"; exit 1; }
grep -q "^  0019-plan-mode-globset-dependency: applied$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost 0019 line"; exit 1; }
grep -q "^  overlay-pin: missing$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost overlay-pin line"; exit 1; }
grep -q "^  weekly-pin: global-default$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost weekly-pin line"; exit 1; }
grep -q "^source-drift: unknown$" "$TMP_DIR/t2.txt" || { echo "FAIL: human status lost source-drift line"; exit 1; }
grep -q '^{' "$TMP_DIR/t2.txt" && { echo "FAIL: human status leaked JSON"; exit 1; }
# Arguments other than --json must not change the human path either.
HOME="$TEST_HOME" GROKGOD_HOME="$GH" GROKGOD_SRC="$SRC" \
  GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" GROKGOD_UPDATE_CHECK_DISABLE=1 \
  sh "$SHIM_SRC" status --verbose > "$TMP_DIR/t2b.txt"
cmp -s "$TMP_DIR/t2.txt" "$TMP_DIR/t2b.txt" || { echo "FAIL: 'status --verbose' diverged from 'status'"; exit 1; }
echo "PASS: Test 2"

# ---------------------------------------------------------------------------
# Test 3: argv0 identity and CLI tolerance for --json
# ---------------------------------------------------------------------------
echo "Test 3: launcher identity and --json argument handling"
BIND="$TMP_DIR/argv0bin"
mkdir -p "$BIND"
cp "$SHIM_SRC" "$BIND/grok"
cp "$SHIM_SRC" "$BIND/grokgod"
chmod +x "$BIND/grok" "$BIND/grokgod"

run_as_grok() {
  HOME="$TEST_HOME" GROKGOD_HOME="$GH" GROKGOD_SRC="$SRC" \
    GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" GROKGOD_UPDATE_CHECK_DISABLE=1 \
    "$BIND/grok" "$@"
}
run_as_grokgod() {
  HOME="$TEST_HOME" GROKGOD_HOME="$GH" GROKGOD_SRC="$SRC" \
    GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" GROKGOD_UPDATE_CHECK_DISABLE=1 \
    "$BIND/grokgod" "$@"
}

run_as_grok status --json > "$TMP_DIR/t3a.json"
[ "$(json_field "$TMP_DIR/t3a.json" launcherIdentity)" = "grok" ] || { echo "FAIL: launcherIdentity not 'grok'"; exit 1; }
run_as_grokgod status --json > "$TMP_DIR/t3b.json"
[ "$(json_field "$TMP_DIR/t3b.json" launcherIdentity)" = "grokgod" ] || { echo "FAIL: launcherIdentity not 'grokgod'"; exit 1; }
run_as_grokgod status -json > "$TMP_DIR/t3c.json"
json_valid "$TMP_DIR/t3c.json" || { echo "FAIL: '-json' did not produce JSON"; exit 1; }
run_as_grokgod status --json extra > "$TMP_DIR/t3d.json"
json_valid "$TMP_DIR/t3d.json" || { echo "FAIL: trailing args broke --json"; exit 1; }
# `--json` before `status` is not a status invocation; it must still reach the
# target binary rather than the JSON path.
run_as_grok --json status > "$TMP_DIR/t3e.txt"
grep -q "FAKE_BIN_CALLED" "$TMP_DIR/t3e.txt" || { echo "FAIL: 'grok --json status' did not reach target binary"; exit 1; }
echo "PASS: Test 3"

# ---------------------------------------------------------------------------
# Test 4: missing binary is corrupt (exit 2)
# ---------------------------------------------------------------------------
echo "Test 4: missing binary -> corrupt"
mv "$BIN" "$TMP_DIR/bin_stash"
set +e
run_json status --json > "$TMP_DIR/t4.json" 2> "$TMP_DIR/t4.err"
T4_STATUS=$?
set -eu
mv "$TMP_DIR/bin_stash" "$BIN"
[ "$T4_STATUS" -eq 2 ] || { echo "FAIL: missing binary exit $T4_STATUS (expected 2)"; exit 1; }
[ ! -s "$TMP_DIR/t4.err" ] || { echo "FAIL: corrupt JSON wrote stderr: $(cat "$TMP_DIR/t4.err")"; exit 1; }
json_valid "$TMP_DIR/t4.json" || { echo "FAIL: corrupt JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t4.json" health)" = "corrupt" ] || { echo "FAIL: expected corrupt health"; exit 1; }
[ "$(json_field "$TMP_DIR/t4.json" patchedBinaryExists)" = "False" ] || { echo "FAIL: patchedBinaryExists should be false"; exit 1; }
[ "$(json_field "$TMP_DIR/t4.json" computedSha256)" = "None" ] || { echo "FAIL: computedSha256 should be null"; exit 1; }
[ "$(json_detail_contains "$TMP_DIR/t4.json" "Patched binary missing at:")" = "yes" ] || { echo "FAIL: missing-binary detail absent"; exit 1; }
echo "PASS: Test 4"

# ---------------------------------------------------------------------------
# Test 5: artifact hash mismatch is corrupt (exit 2)
# ---------------------------------------------------------------------------
echo "Test 5: artifact hash mismatch -> corrupt"
write_manifest "0000000000000000000000000000000000000000000000000000000000000000" release "$BIN_SHA" "unsigned"
set +e
run_json status --json > "$TMP_DIR/t5.json" 2> "$TMP_DIR/t5.err"
T5_STATUS=$?
set -eu
[ "$T5_STATUS" -eq 2 ] || { echo "FAIL: hash mismatch exit $T5_STATUS (expected 2)"; exit 1; }
[ ! -s "$TMP_DIR/t5.err" ] || { echo "FAIL: mismatch wrote stderr"; exit 1; }
json_valid "$TMP_DIR/t5.json" || { echo "FAIL: mismatch JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t5.json" health)" = "corrupt" ] || { echo "FAIL: expected corrupt on hash mismatch"; exit 1; }
[ "$(json_field "$TMP_DIR/t5.json" artifactHashMatchesRecord)" = "False" ] || { echo "FAIL: artifactHashMatchesRecord should be false"; exit 1; }
[ "$(json_detail_contains "$TMP_DIR/t5.json" "does not match recorded artifact SHA")" = "yes" ] || { echo "FAIL: mismatch detail absent"; exit 1; }
echo "PASS: Test 5"

# ---------------------------------------------------------------------------
# Test 6: missing / malformed manifest and stamp
# ---------------------------------------------------------------------------
echo "Test 6: missing and malformed manifest/stamp"
# 6a: legacy install — valid stamp, no manifest -> healthy, no false corrupt.
rm -f "$MANIFEST"
write_stamp "SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=release"
set +e
run_json status --json > "$TMP_DIR/t6a.json" 2> "$TMP_DIR/t6a.err"
T6A_STATUS=$?
set -eu
[ "$T6A_STATUS" -eq 0 ] || { echo "FAIL: legacy (no manifest) exit $T6A_STATUS (expected 0)"; exit 1; }
[ ! -s "$TMP_DIR/t6a.err" ] || { echo "FAIL: legacy JSON wrote stderr"; exit 1; }
json_valid "$TMP_DIR/t6a.json" || { echo "FAIL: legacy JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6a.json" health)" = "healthy" ] || { echo "FAIL: legacy install should stay healthy"; exit 1; }
[ "$(json_field "$TMP_DIR/t6a.json" manifestExists)" = "False" ] || { echo "FAIL: manifestExists should be false"; exit 1; }
[ "$(json_field "$TMP_DIR/t6a.json" artifactSha256)" = "None" ] || { echo "FAIL: artifactSha256 should be null without manifest"; exit 1; }
[ "$(json_field "$TMP_DIR/t6a.json" manifestDetail)" != "None" ] || { echo "FAIL: manifestDetail should explain the absence"; exit 1; }

# 6b: truncated manifest -> ignored, stamp-only health preserved.
printf '{"formatVersion": 1,' > "$MANIFEST"
set +e
run_json status --json > "$TMP_DIR/t6b.json" 2> "$TMP_DIR/t6b.err"
T6B_STATUS=$?
set -eu
[ "$T6B_STATUS" -eq 0 ] || { echo "FAIL: truncated manifest exit $T6B_STATUS (expected 0)"; exit 1; }
json_valid "$TMP_DIR/t6b.json" || { echo "FAIL: truncated-manifest JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6b.json" health)" = "healthy" ] || { echo "FAIL: truncated manifest must not change health"; exit 1; }
[ "$(json_field "$TMP_DIR/t6b.json" manifestValid)" = "False" ] || { echo "FAIL: truncated manifest should be invalid"; exit 1; }
[ "$(json_detail_contains "$TMP_DIR/t6b.json" "malformed")" = "yes" ] || { echo "FAIL: malformed manifest detail absent"; exit 1; }
[ "$(json_field "$TMP_DIR/t6b.json" artifactSha256)" = "None" ] || { echo "FAIL: truncated manifest must not supply a hash"; exit 1; }

# 6c: garbage manifest -> ignored.
printf 'not json at all\n' > "$MANIFEST"
set +e
run_json status --json > "$TMP_DIR/t6c.json" 2> "$TMP_DIR/t6c.err"
T6C_STATUS=$?
set -eu
[ "$T6C_STATUS" -eq 0 ] || { echo "FAIL: garbage manifest exit $T6C_STATUS (expected 0)"; exit 1; }
[ ! -s "$TMP_DIR/t6c.err" ] || { echo "FAIL: garbage manifest wrote stderr: $(cat "$TMP_DIR/t6c.err")"; exit 1; }
json_valid "$TMP_DIR/t6c.json" || { echo "FAIL: garbage-manifest JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6c.json" manifestValid)" = "False" ] || { echo "FAIL: garbage manifest should be invalid"; exit 1; }

# 6d: Windows-style manifest (no platform field) must be ignored, not trusted.
printf '{\n  "formatVersion": 1,\n  "artifactSha256": "%s"\n}\n' "$BIN_SHA" > "$MANIFEST"
set +e
run_json status --json > "$TMP_DIR/t6d.json" 2> "$TMP_DIR/t6d.err"
T6D_STATUS=$?
set -eu
[ "$T6D_STATUS" -eq 0 ] || { echo "FAIL: foreign manifest exit $T6D_STATUS (expected 0)"; exit 1; }
[ ! -s "$TMP_DIR/t6d.err" ] || { echo "FAIL: foreign manifest wrote stderr: $(cat "$TMP_DIR/t6d.err")"; exit 1; }
[ "$(json_field "$TMP_DIR/t6d.json" manifestValid)" = "False" ] || { echo "FAIL: manifest without platform=posix must be invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6d.json" artifactSha256)" = "None" ] || { echo "FAIL: foreign manifest must not supply artifactSha256"; exit 1; }

# 6d2: syntactically broken JSON (missing / trailing comma) must be rejected
# rather than half-read by the per-key extraction.
printf '{\n  "formatVersion": 1\n  "platform": "posix",\n  "artifactSha256": "%s"\n}\n' "$BIN_SHA" > "$MANIFEST"
set +e
run_json status --json > "$TMP_DIR/t6d2.json"
T6D2_STATUS=$?
set -eu
[ "$T6D2_STATUS" -eq 0 ] || { echo "FAIL: missing-comma manifest exit $T6D2_STATUS (expected 0)"; exit 1; }
json_valid "$TMP_DIR/t6d2.json" || { echo "FAIL: missing-comma JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6d2.json" manifestValid)" = "False" ] || { echo "FAIL: missing-comma manifest must be invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6d2.json" artifactSha256)" = "None" ] || { echo "FAIL: missing-comma manifest must not supply artifactSha256"; exit 1; }

printf '{\n  "formatVersion": 1,\n  "platform": "posix",\n  "artifactSha256": "%s",\n}\n' "$BIN_SHA" > "$MANIFEST"
set +e
run_json status --json > "$TMP_DIR/t6d3.json"
T6D3_STATUS=$?
set -eu
[ "$T6D3_STATUS" -eq 0 ] || { echo "FAIL: trailing-comma manifest exit $T6D3_STATUS (expected 0)"; exit 1; }
[ "$(json_field "$TMP_DIR/t6d3.json" manifestValid)" = "False" ] || { echo "FAIL: trailing-comma manifest must be invalid"; exit 1; }

# 6e: valid manifest, missing stamp -> degraded (exit 1), values from manifest.
write_manifest "$BIN_SHA" source "$BIN_SHA" "unsigned"
rm -f "$STAMP"
set +e
run_json status --json > "$TMP_DIR/t6e.json" 2> "$TMP_DIR/t6e.err"
T6E_STATUS=$?
set -eu
[ "$T6E_STATUS" -eq 1 ] || { echo "FAIL: missing stamp exit $T6E_STATUS (expected 1)"; exit 1; }
[ ! -s "$TMP_DIR/t6e.err" ] || { echo "FAIL: degraded JSON wrote stderr"; exit 1; }
json_valid "$TMP_DIR/t6e.json" || { echo "FAIL: missing-stamp JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6e.json" health)" = "degraded" ] || { echo "FAIL: expected degraded without stamp"; exit 1; }
[ "$(json_detail_contains "$TMP_DIR/t6e.json" "Stamp file missing at:")" = "yes" ] || { echo "FAIL: missing-stamp detail absent"; exit 1; }
# patchStatus keeps the human rule: binary present AND stamp PATCHSET present.
[ "$(json_field "$TMP_DIR/t6e.json" patchStatus)" = "missing" ] || { echo "FAIL: patchStatus should be missing without a stamp"; exit 1; }
# The manifest still supplies the packaging metadata when the stamp is gone.
[ "$(json_field "$TMP_DIR/t6e.json" mode)" = "source" ] || { echo "FAIL: mode should fall back to the manifest"; exit 1; }

# 6f: malformed stamp (no SHA) -> degraded.
write_stamp "MODE=release
VERSION=v1.2.3"
set +e
run_json status --json > "$TMP_DIR/t6f.json" 2> "$TMP_DIR/t6f.err"
T6F_STATUS=$?
set -eu
[ "$T6F_STATUS" -eq 1 ] || { echo "FAIL: malformed stamp exit $T6F_STATUS (expected 1)"; exit 1; }
json_valid "$TMP_DIR/t6f.json" || { echo "FAIL: malformed-stamp JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6f.json" health)" = "degraded" ] || { echo "FAIL: expected degraded on malformed stamp"; exit 1; }
[ "$(json_detail_contains "$TMP_DIR/t6f.json" "malformed or missing recorded SHA")" = "yes" ] || { echo "FAIL: malformed-stamp detail absent"; exit 1; }
[ "$(json_field "$TMP_DIR/t6f.json" patchStatus)" = "missing" ] || { echo "FAIL: patchStatus should be missing without PATCHSET"; exit 1; }

# 6g: unknown MODE -> degraded.
write_stamp "SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=banana"
set +e
run_json status --json > "$TMP_DIR/t6g.json" 2> "$TMP_DIR/t6g.err"
T6G_STATUS=$?
set -eu
[ "$T6G_STATUS" -eq 1 ] || { echo "FAIL: unknown MODE exit $T6G_STATUS (expected 1)"; exit 1; }
[ ! -s "$TMP_DIR/t6g.err" ] || { echo "FAIL: unknown MODE wrote stderr: $(cat "$TMP_DIR/t6g.err")"; exit 1; }
json_valid "$TMP_DIR/t6g.json" || { echo "FAIL: unknown-MODE JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6g.json" health)" = "degraded" ] || { echo "FAIL: expected degraded on unknown MODE"; exit 1; }

# 6h: release stamp whose SHA is not a sha256 -> degraded.
write_stamp "SHA=deadbeef
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=release"
set +e
run_json status --json > "$TMP_DIR/t6h.json" 2> "$TMP_DIR/t6h.err"
T6H_STATUS=$?
set -eu
[ "$T6H_STATUS" -eq 1 ] || { echo "FAIL: short release SHA exit $T6H_STATUS (expected 1)"; exit 1; }
[ ! -s "$TMP_DIR/t6h.err" ] || { echo "FAIL: short release SHA wrote stderr: $(cat "$TMP_DIR/t6h.err")"; exit 1; }
json_valid "$TMP_DIR/t6h.json" || { echo "FAIL: short-SHA JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t6h.json" health)" = "degraded" ] || { echo "FAIL: expected degraded on short release SHA"; exit 1; }

# 6i: a duplicated non-decisional key is reported but keeps health intact.
write_stamp "SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
VERSION=v1.2.3
MODE=release"
write_manifest "$BIN_SHA" release "$BIN_SHA" "unsigned"
set +e
run_json status --json > "$TMP_DIR/t6i.json"
T6I_STATUS=$?
set -eu
[ "$T6I_STATUS" -eq 0 ] || { echo "FAIL: duplicate VERSION exit $T6I_STATUS (expected 0)"; exit 1; }
json_valid "$TMP_DIR/t6i.json" || { echo "FAIL: duplicate-key JSON invalid"; exit 1; }
[ "$(json_detail_contains "$TMP_DIR/t6i.json" "duplicate VERSION= lines")" = "yes" ] || { echo "FAIL: duplicate-key detail absent"; exit 1; }
[ "$(json_field "$TMP_DIR/t6i.json" health)" = "healthy" ] || { echo "FAIL: duplicate VERSION must not degrade health"; exit 1; }

# 6j: a duplicated SHA is fail-closed — the grep-based readers would otherwise
# see a multi-line value and silently misreport the artifact.
write_stamp "SHA=$BIN_SHA
SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=release"
printf '{\n  "formatVersion": 1,\n  "platform": "posix",\n  "artifactSha256": "%s",\n  "sourceSha": "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0"\n}\n' "$BIN_SHA" > "$MANIFEST"
set +e
run_json status --json > "$TMP_DIR/t6j.json"
T6J_STATUS=$?
set -eu
[ "$T6J_STATUS" -eq 1 ] || { echo "FAIL: duplicate SHA exit $T6J_STATUS (expected 1)"; exit 1; }
json_valid "$TMP_DIR/t6j.json" || { echo "FAIL: duplicate-SHA JSON invalid"; exit 1; }
[ "$(json_detail_contains "$TMP_DIR/t6j.json" "duplicate SHA= lines")" = "yes" ] || { echo "FAIL: duplicate SHA detail absent"; exit 1; }
[ "$(json_field "$TMP_DIR/t6j.json" health)" = "degraded" ] || { echo "FAIL: duplicate SHA must degrade health"; exit 1; }
# A multi-line stamp value must never split one diagnostic across two
# healthDetails entries (a valid manifest with a differing sourceSha is the
# case that would otherwise interpolate the raw multi-line SHA).
python3 - "$TMP_DIR/t6j.json" << 'PY' || { echo "FAIL: duplicate-SHA detail was split across array entries"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert len(d["healthDetails"]) == 1, d["healthDetails"]
assert "duplicate SHA= lines" in d["healthDetails"][0]
PY
# 6k: the manifest trust gates are individually reachable and fail closed.
# (Each mutation of these gates used to leave the suite green.)
write_stamp "SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=release"
for gate in "formatVersion 2" "platform windows" "artifactSha256 duplicated"; do
  case "$gate" in
    formatVersion*) printf '{\n  "formatVersion": 2,\n  "platform": "posix",\n  "artifactSha256": "%s"\n}\n' "$BIN_SHA" > "$MANIFEST" ;;
    platform*) printf '{\n  "formatVersion": 1,\n  "platform": "windows",\n  "artifactSha256": "%s"\n}\n' "$BIN_SHA" > "$MANIFEST" ;;
    *) printf '{\n  "formatVersion": 1,\n  "platform": "posix",\n  "artifactSha256": "%s",\n  "artifactSha256": "%s"\n}\n' "$BIN_SHA" "$BIN_SHA" > "$MANIFEST" ;;
  esac
  set +e
  run_json status --json > "$TMP_DIR/t6k.json" 2> "$TMP_DIR/t6k.err"
  T6K_STATUS=$?
  set -eu
  [ "$T6K_STATUS" -eq 0 ] || { echo "FAIL: gate '$gate' exit $T6K_STATUS (expected 0)"; exit 1; }
  [ ! -s "$TMP_DIR/t6k.err" ] || { echo "FAIL: gate '$gate' wrote stderr"; exit 1; }
  json_valid "$TMP_DIR/t6k.json" || { echo "FAIL: gate '$gate' JSON invalid"; exit 1; }
  [ "$(json_field "$TMP_DIR/t6k.json" manifestValid)" = "False" ] || {
    echo "FAIL: gate '$gate' was not enforced (manifestValid=true)"; exit 1
  }
  [ "$(json_field "$TMP_DIR/t6k.json" artifactSha256)" = "None" ] || {
    echo "FAIL: gate '$gate' still supplied an artifact digest"; exit 1
  }
done
# A manifest/timestamp fallback must not leak when the stamp is absent.
write_manifest "$BIN_SHA" release "$BIN_SHA" "unsigned"
rm -f "$STAMP"
set +e
run_json status --json > "$TMP_DIR/t6l.json"
set -eu
[ "$(json_field "$TMP_DIR/t6l.json" version)" = "v1.2.3" ] || {
  echo "FAIL: version fallback from the manifest is not wired"; exit 1
}
[ "$(json_field "$TMP_DIR/t6l.json" patchset)" = "v1.2.3" ] || {
  echo "FAIL: patchset fallback from the manifest is not wired"; exit 1
}
echo "PASS: Test 6"

# ---------------------------------------------------------------------------
# Test 7: signature recording and verification
# ---------------------------------------------------------------------------
echo "Test 7: signature fields"
write_stamp "SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=release"
LIVE_SIG="$(json_field "$TMP_DIR/t1.json" signature)"
write_manifest "$BIN_SHA" release "$BIN_SHA" "$LIVE_SIG"
set +e
run_json status --json > "$TMP_DIR/t7a.json"
T7A_STATUS=$?
set -eu
[ "$T7A_STATUS" -eq 0 ] || { echo "FAIL: matching recorded signature exit $T7A_STATUS"; exit 1; }
[ "$(json_field "$TMP_DIR/t7a.json" recordedSignature)" = "$LIVE_SIG" ] || { echo "FAIL: recordedSignature not read from manifest"; exit 1; }
[ "$(json_field "$TMP_DIR/t7a.json" signatureVerified)" = "True" ] || { echo "FAIL: signatureVerified should be true on agreement"; exit 1; }

write_manifest "$BIN_SHA" release "$BIN_SHA" "definitely-not-the-live-signature"
set +e
run_json status --json > "$TMP_DIR/t7b.json"
T7B_STATUS=$?
set -eu
json_valid "$TMP_DIR/t7b.json" || { echo "FAIL: mismatch-signature JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t7b.json" signatureVerified)" = "False" ] || { echo "FAIL: signatureVerified should be false on disagreement"; exit 1; }
[ "$(json_detail_contains "$TMP_DIR/t7b.json" "Signature recorded as")" = "yes" ] || { echo "FAIL: signature mismatch detail absent"; exit 1; }
# A signature observation is not a health decision: only the reason differs.
[ "$T7B_STATUS" -eq "$T7A_STATUS" ] || { echo "FAIL: signature mismatch changed the exit code ($T7B_STATUS vs $T7A_STATUS)"; exit 1; }

# An unusable recorded digest must not read as 'nothing to verify'.
write_manifest "" release "$BIN_SHA" "$LIVE_SIG"
set +e
run_json status --json > "$TMP_DIR/t7c.json"
T7C_STATUS=$?
set -eu
json_valid "$TMP_DIR/t7c.json" || { echo "FAIL: unusable recorded digest broke JSON"; exit 1; }
[ "$T7C_STATUS" -eq 2 ] || { echo "FAIL: unusable recorded artifactSha256 exit $T7C_STATUS (expected 2)"; exit 1; }
[ "$(json_field "$TMP_DIR/t7c.json" health)" = "corrupt" ] || { echo "FAIL: unusable recorded artifactSha256 must be corrupt"; exit 1; }
# 7d: launcher ownership values (shim / foreign / absent).
printf '#!/bin/sh\necho "not ours"\n' > "$LAUNCHER"
printf 'SHA=%s\nPATCHSET=v1.2.3\nVERSION=v1.2.3\nMODE=release\n' "$BIN_SHA" > "$STAMP"
write_manifest "$BIN_SHA" release "$BIN_SHA" "unsigned"
run_json status --json > "$TMP_DIR/t7d.json"
[ "$(json_field "$TMP_DIR/t7d.json" launcherOwnership)" = "foreign" ] || {
  echo "FAIL: expected launcherOwnership foreign, got $(json_field "$TMP_DIR/t7d.json" launcherOwnership)"; exit 1
}
rm -f "$LAUNCHER"
run_json status --json > "$TMP_DIR/t7e.json"
[ "$(json_field "$TMP_DIR/t7e.json" launcherOwnership)" = "absent" ] || {
  echo "FAIL: expected launcherOwnership absent, got $(json_field "$TMP_DIR/t7e.json" launcherOwnership)"; exit 1
}
printf '# GROKGOD shim\n' > "$LAUNCHER"
run_json status --json > "$TMP_DIR/t7f.json"
[ "$(json_field "$TMP_DIR/t7f.json" launcherOwnership)" = "shim" ] || {
  echo "FAIL: expected launcherOwnership shim"; exit 1
}
echo "PASS: Test 7"
# ---------------------------------------------------------------------------
echo "Test 8: hostile stamp/manifest content stays valid JSON"
write_stamp 'SHA="quote\backslash
VERSION=multi
line
MODE=release'
printf '{"formatVersion": 1, "platform": "posix", "artifactSha256": "%s", "note": "raw\ttab and \"quotes\""}\n' "$BIN_SHA" > "$MANIFEST"
set +e
run_json status --json > "$TMP_DIR/t8.json" 2> "$TMP_DIR/t8.err"
T8_STATUS=$?
set -eu
[ ! -s "$TMP_DIR/t8.err" ] || { echo "FAIL: hostile input wrote stderr"; exit 1; }
json_valid "$TMP_DIR/t8.json" || { echo "FAIL: hostile input broke JSON"; cat "$TMP_DIR/t8.json"; exit 1; }
case "$T8_STATUS" in
  0|1|2) : ;;
  *) echo "FAIL: hostile input produced unexpected exit $T8_STATUS"; exit 1 ;;
esac
python3 - "$TMP_DIR/t8.json" << 'PY' || { echo "FAIL: hostile signature/stamp values did not round-trip as strings"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert isinstance(d["signature"], str), d["signature"]
assert d["manifestPath"].endswith("manifest.json")
assert "\r" not in json.dumps(d)
PY

# 8b: bytes that are not valid UTF-8 must not reach stdout raw, and must not
# make the shell tools write to stderr. Octal escapes: \xNN is a bash-ism.
printf 'SHA=%s\nPATCHSET=v1\nVERSION=raw\377\376\351byte\nMODE=release\n' "$BIN_SHA" > "$STAMP"
set +e
run_json status --json > "$TMP_DIR/t8b.json" 2> "$TMP_DIR/t8b.err"
T8B_STATUS=$?
set -eu
[ ! -s "$TMP_DIR/t8b.err" ] || { echo "FAIL: invalid-UTF8 stamp wrote stderr: $(cat "$TMP_DIR/t8b.err")"; exit 1; }
json_valid "$TMP_DIR/t8b.json" || { echo "FAIL: invalid-UTF8 stamp broke JSON"; exit 1; }
case "$T8B_STATUS" in
  0|1|2) : ;;
  *) echo "FAIL: invalid-UTF8 stamp exit $T8B_STATUS"; exit 1 ;;
esac

# 8c: valid multi-byte text survives the sanitizer.
printf 'SHA=%s\nPATCHSET=v1\nVERSION=caf\303\251\nMODE=release\n' "$BIN_SHA" > "$STAMP"
run_json status --json > "$TMP_DIR/t8c.json"
json_valid "$TMP_DIR/t8c.json" || { echo "FAIL: valid UTF-8 stamp broke JSON"; exit 1; }
python3 - "$TMP_DIR/t8c.json" << 'PY' || { echo "FAIL: valid UTF-8 version was mangled"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert d["version"] == "café", repr(d["version"])
PY

# 8d: an unreadable/directory target is corrupt, and still valid JSON.
write_stamp "SHA=$BIN_SHA
PATCHSET=v1
VERSION=v1
MODE=release"
mv "$BIN" "$TMP_DIR/bin_stash8"
mkdir -p "$BIN"
set +e
run_json status --json > "$TMP_DIR/t8d.json" 2> "$TMP_DIR/t8d.err"
T8D_STATUS=$?
set -eu
rmdir "$BIN"
mv "$TMP_DIR/bin_stash8" "$BIN"
[ "$T8D_STATUS" -eq 2 ] || { echo "FAIL: non-regular binary exit $T8D_STATUS (expected 2)"; exit 1; }
[ ! -s "$TMP_DIR/t8d.err" ] || { echo "FAIL: non-regular binary wrote stderr"; exit 1; }
json_valid "$TMP_DIR/t8d.json" || { echo "FAIL: non-regular binary JSON invalid"; exit 1; }
[ "$(json_field "$TMP_DIR/t8d.json" health)" = "corrupt" ] || { echo "FAIL: non-regular binary must be corrupt"; exit 1; }

# The human path must still work with the same hostile stamp.
printf 'SHA="quote\\backslash\nVERSION=multi\nline\nMODE=release\n' > "$STAMP"
HOME="$TEST_HOME" GROKGOD_HOME="$GH" GROKGOD_SRC="$SRC" \
  GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" GROKGOD_UPDATE_CHECK_DISABLE=1 \
  sh "$SHIM_SRC" status > "$TMP_DIR/t8.txt" 2> "$TMP_DIR/t8h.err"
[ ! -s "$TMP_DIR/t8h.err" ] || { echo "FAIL: hostile input broke human status stderr"; exit 1; }
grep -q "^shim: " "$TMP_DIR/t8.txt" || { echo "FAIL: hostile input broke human status"; exit 1; }
echo "PASS: Test 8"

# ---------------------------------------------------------------------------
# Test 9: --json has no side effects and no update-check traffic
# ---------------------------------------------------------------------------
echo "Test 9: status --json side effects"
write_stamp "SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=release"
write_manifest "$BIN_SHA" release "$BIN_SHA" "unsigned"
rm -f "$GH/.update-check"
ls -A "$GH" > "$TMP_DIR/before.txt"
STAMP_BEFORE="$(cat "$STAMP")"
MANIFEST_BEFORE="$(cat "$MANIFEST")"
run_json status --json > /dev/null
ls -A "$GH" > "$TMP_DIR/after.txt"
cmp -s "$TMP_DIR/before.txt" "$TMP_DIR/after.txt" || {
  echo "FAIL: status --json changed GROKGOD_HOME contents"
  diff "$TMP_DIR/before.txt" "$TMP_DIR/after.txt" || true
  exit 1
}
[ ! -e "$GH/.update-check" ] || { echo "FAIL: status --json created the update-check cache"; exit 1; }
[ "$(cat "$STAMP")" = "$STAMP_BEFORE" ] || { echo "FAIL: status --json rewrote the stamp"; exit 1; }
[ "$(cat "$MANIFEST")" = "$MANIFEST_BEFORE" ] || { echo "FAIL: status --json rewrote the manifest"; exit 1; }
echo "PASS: Test 9"

# ---------------------------------------------------------------------------
# Test 10: install.sh writes the manifest at the stamp commit points
# ---------------------------------------------------------------------------
echo "Test 10: install.sh artifact manifest writer"
if [ ! -f "$INSTALL_SRC" ]; then
  echo "FAIL: install.sh not found at $INSTALL_SRC" >&2
  exit 1
fi
{
  # Extract only the writer helpers from install.sh and exercise them with an
  # isolated GROKGOD_HOME, so no network/cargo/uninstall path is involved.
  awk '/^manifest_file_sha256\(\)/,/^compute_patchset_id\(\)/' "$INSTALL_SRC" | sed '$d' > "$TMP_DIR/writer.sh"
  grep -q 'write_artifact_manifest()' "$TMP_DIR/writer.sh" || {
    echo "FAIL: could not extract write_artifact_manifest from install.sh"; exit 1
  }
  cat << 'EOF' > "$TMP_DIR/writer_driver.sh"
#!/bin/sh
set -eu
GROKGOD_HOME="$1"
log_warn() { printf 'WARN %s\n' "$1" >&2; }
. "$2"
write_artifact_manifest release v9.9.9 v9.9.9 abc123 abc123
write_artifact_manifest source deadbeef patchset-7 deadbeef ""
EOF
  WFIX="$TMP_DIR/wfix"
  mkdir -p "$WFIX/bin"
  printf '#!/bin/sh\necho fixture\n' > "$WFIX/bin/grok"
  chmod +x "$WFIX/bin/grok"
  sh "$TMP_DIR/writer_driver.sh" "$WFIX" "$TMP_DIR/writer.sh" > "$TMP_DIR/t10.out" 2> "$TMP_DIR/t10.err"
  [ -f "$WFIX/manifest.json" ] || { echo "FAIL: writer did not create manifest.json"; exit 1; }
  json_valid "$WFIX/manifest.json" || { echo "FAIL: written manifest is not valid JSON"; cat "$WFIX/manifest.json"; exit 1; }
  [ "$(json_field "$WFIX/manifest.json" platform)" = "posix" ] || { echo "FAIL: platform is not posix"; exit 1; }
  [ "$(json_field "$WFIX/manifest.json" mode)" = "source" ] || { echo "FAIL: second write did not replace the manifest"; exit 1; }
  [ "$(json_field "$WFIX/manifest.json" assetSha256)" = "" ] || { echo "FAIL: source-mode assetSha256 should be empty"; exit 1; }
  FIX_SHA="$(sha_of "$WFIX/bin/grok")"
  [ "$(json_field "$WFIX/manifest.json" artifactSha256)" = "$FIX_SHA" ] || {
    echo "FAIL: artifactSha256 is not the digest of the installed binary"; exit 1
  }
  [ "$(json_field "$WFIX/manifest.json" sourceSha)" = "deadbeef" ] || { echo "FAIL: sourceSha not recorded"; exit 1; }
  [ "$(json_field "$WFIX/manifest.json" patchset)" = "patchset-7" ] || { echo "FAIL: patchset not recorded"; exit 1; }
  # No stray temp file is left behind on the success path.
  ls "$WFIX" | grep -q 'manifest.json.tmp' && { echo "FAIL: temp manifest left behind"; exit 1; }

  # The writer must never fail the install when the target cannot be written.
  RO_HOME="$TMP_DIR/rohome"
  mkdir -p "$RO_HOME/bin"
  chmod 500 "$RO_HOME"
  set +e
  sh "$TMP_DIR/writer_driver.sh" "$RO_HOME" "$TMP_DIR/writer.sh" > "$TMP_DIR/t10b.out" 2> "$TMP_DIR/t10b.err"
  T10B_STATUS=$?
  chmod 700 "$RO_HOME"
  set -eu
  [ "$T10B_STATUS" -eq 0 ] || { echo "FAIL: unwritable home made the writer exit $T10B_STATUS"; exit 1; }

  # Round-trip: what the writer produces must be what the shim reads. This is
  # the only check that pins both sides of the manifest contract together.
  printf 'SHA=%s\nPATCHSET=v9.9.9\nVERSION=v9.9.9\nMODE=release\n' "$FIX_SHA" > "$WFIX/.source-version"
  sh "$TMP_DIR/writer_driver.sh" "$WFIX" "$TMP_DIR/writer.sh" > /dev/null 2>&1
  HOME="$WFIX" GROKGOD_HOME="$WFIX" GROKGOD_SRC="$SRC" \
    GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" GROKGOD_UPDATE_CHECK_DISABLE=1 \
    sh "$SHIM_SRC" status --json > "$TMP_DIR/t10c.json" 2> "$TMP_DIR/t10c.err"
  [ ! -s "$TMP_DIR/t10c.err" ] || { echo "FAIL: round-trip wrote stderr"; exit 1; }
  json_valid "$TMP_DIR/t10c.json" || { echo "FAIL: round-trip JSON invalid"; exit 1; }
  [ "$(json_field "$TMP_DIR/t10c.json" manifestValid)" = "True" ] || {
    echo "FAIL: shim rejected a manifest install.sh wrote: $(json_field "$TMP_DIR/t10c.json" manifestDetail)"
    exit 1
  }
  [ "$(json_field "$TMP_DIR/t10c.json" manifestExists)" = "True" ] || { echo "FAIL: round-trip manifestExists"; exit 1; }
  [ "$(json_field "$TMP_DIR/t10c.json" artifactHashMatchesRecord)" = "True" ] || {
    echo "FAIL: round-trip artifact hash mismatch"; exit 1
  }
  [ "$(json_field "$TMP_DIR/t10c.json" health)" = "healthy" ] || {
    echo "FAIL: round-trip health is $(json_field "$TMP_DIR/t10c.json" health)"; exit 1
  }
  [ "$(json_field "$TMP_DIR/t10c.json" signatureVerified)" = "True" ] || {
    echo "FAIL: round-trip signatureVerified is $(json_field "$TMP_DIR/t10c.json" signatureVerified)"
    exit 1
  }
  [ "$(json_field "$TMP_DIR/t10c.json" patchset)" = "v9.9.9" ] || { echo "FAIL: round-trip patchset"; exit 1; }
  [ "$(json_field "$TMP_DIR/t10c.json" sourceSha)" = "deadbeef" ] || { echo "FAIL: round-trip sourceSha"; exit 1; }

  # Stamp writes at the two commit points must remain byte-compatible.
  grep -q 'printf "SHA=%s\\nPATCHSET=%s\\nVERSION=%s\\nMODE=release\\n"' "$INSTALL_SRC" || {
    echo "FAIL: release stamp printf changed"; exit 1
  }
  grep -q 'printf "SHA=%s\\nPATCHSET=%s\\nVERSION=%s\\nMODE=source\\n"' "$INSTALL_SRC" || {
    echo "FAIL: source stamp printf changed"; exit 1
  }
  # The commit point must build the manifest from the activated post-codesign
  # binary and stage it under the transaction's sibling temp name, then rename
  # it into place; a dropped argument or a non-atomic write silently degrades
  # or tears the record, so pin the full call shape.
  grep -q 'write_artifact_manifest "\$MANIFEST_MODE" "\$MANIFEST_VERSION" "\$MANIFEST_PATCHSET"' "$INSTALL_SRC" || {
    echo "FAIL: commit-point call shape changed"; exit 1
  }
  grep -q '"\$MANIFEST_SOURCE_SHA" "\$MANIFEST_ASSET_SHA" "\$_manifest_tmp"' "$INSTALL_SRC" || {
    echo "FAIL: commit-point tail arguments changed"; exit 1
  }
  grep -q 'mv -f "\$_manifest_tmp" "\$GROKGOD_HOME/manifest.json"' "$INSTALL_SRC" || {
    echo "FAIL: manifest is not renamed into place atomically"; exit 1
  }
}
echo "PASS: Test 10"

# ---------------------------------------------------------------------------
# Test 11: dash compatibility when available
# ---------------------------------------------------------------------------
echo "Test 11: POSIX shell matrix"
if command -v dash >/dev/null 2>&1; then
  write_stamp "SHA=$BIN_SHA
PATCHSET=v1.2.3
VERSION=v1.2.3
MODE=release"
  write_manifest "$BIN_SHA" release "$BIN_SHA" "unsigned"
  HOME="$TEST_HOME" GROKGOD_HOME="$GH" GROKGOD_SRC="$SRC" \
    GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" GROKGOD_UPDATE_CHECK_DISABLE=1 \
    dash "$SHIM_SRC" status --json > "$TMP_DIR/t11.json" 2> "$TMP_DIR/t11.err"
  json_valid "$TMP_DIR/t11.json" || { echo "FAIL: dash JSON invalid"; exit 1; }
  [ ! -s "$TMP_DIR/t11.err" ] || { echo "FAIL: dash JSON wrote stderr"; exit 1; }
  HOME="$TEST_HOME" GROKGOD_HOME="$GH" GROKGOD_SRC="$SRC" \
    GROK_BUILD_SRC="$TMP_DIR/nonexistent_grok_build" GROKGOD_UPDATE_CHECK_DISABLE=1 \
    dash "$SHIM_SRC" status > "$TMP_DIR/t11.txt"
  grep -q "^persist:$" "$TMP_DIR/t11.txt" || { echo "FAIL: dash human status broken"; exit 1; }
  echo "  note: exercised dash"
else
  echo "  note: dash not installed; skipped"
fi
echo "PASS: Test 11"

echo "=== All POSIX manifest/status tests passed successfully! ==="
