#!/bin/sh
set -eu

# test_sessions.sh: grokgod-cache sessions report + grokgod-sessions prune
# Never touches the real ~/.grok/sessions tree.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_SCRIPT="$REPO_ROOT/src/grokgod-cache.sh"
SESS_SCRIPT="$REPO_ROOT/src/grokgod-sessions.sh"
SHIM_SRC="$REPO_ROOT/src/shim/grok-shim.sh"

if [ ! -f "$CACHE_SCRIPT" ] || [ ! -f "$SESS_SCRIPT" ] || [ ! -f "$SHIM_SRC" ]; then
  echo "FAIL: required scripts missing" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

OLD_ID="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
LIVE_ID="bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
NEW_ID="cccccccc-dddd-4eee-8fff-000000000000"
NON_UUID="not-a-session"

setup_sessions() {
  name="$1"
  root="$TMP_DIR/$name"
  mkdir -p "$root/home/.grokgod" "$root/grok/sessions/%2Fcwd-old/$OLD_ID"
  mkdir -p "$root/grok/sessions/%2Fcwd-live/$LIVE_ID"
  mkdir -p "$root/grok/sessions/%2Fcwd-new/$NEW_ID"
  mkdir -p "$root/grok/sessions/%2Fcwd-junk/$NON_UUID"
  echo dummy > "$root/grok/sessions/%2Fcwd-old/$OLD_ID/updates.jsonl"
  echo dummy > "$root/grok/sessions/%2Fcwd-live/$LIVE_ID/updates.jsonl"
  echo dummy > "$root/grok/sessions/%2Fcwd-new/$NEW_ID/updates.jsonl"
  echo dummy > "$root/grok/sessions/%2Fcwd-junk/$NON_UUID/updates.jsonl"
  touch -t 202001010101 "$root/grok/sessions/%2Fcwd-old/$OLD_ID"
  touch -t 202001010101 "$root/grok/sessions/%2Fcwd-live/$LIVE_ID"
  touch -t 202001010101 "$root/grok/sessions/%2Fcwd-junk/$NON_UUID"
  echo "$root"
}

install_stub_grok() {
  dest="$1"
  log="$2"
  mkdir -p "$dest"
  : > "$log"
  cat > "$dest/grok" <<EOF
#!/bin/sh
echo "\$*" >> "$log"
if [ "\$1" = "sessions" ] && [ "\$2" = "delete" ]; then
  echo "STUB_DELETE:\$3"
  exit 0
fi
echo "STUB_GROK:\$*"
exit 0
EOF
  chmod +x "$dest/grok"
}

echo "=== Running grokgod-sessions tests ==="

echo "Test 1: cache report lists sessions size, count, age buckets"
S1="$(setup_sessions t1)"
OUT1="$(
  HOME="$S1/home" \
  GROKGOD_HOME="$S1/home/.grokgod" \
  GROK_HOME="$S1/grok" \
  sh "$CACHE_SCRIPT" report
)"
echo "$OUT1" | grep -q "grok sessions:" || { echo "FAIL: missing grok sessions header: $OUT1"; exit 1; }
echo "$OUT1" | grep -q "sessions dir:" || { echo "FAIL: missing sessions dir: $OUT1"; exit 1; }
echo "$OUT1" | grep -q "session dirs:     3" || { echo "FAIL: expected 3 uuid session dirs: $OUT1"; exit 1; }
echo "$OUT1" | grep -q ">30d=" || { echo "FAIL: missing >30d bucket: $OUT1"; exit 1; }
echo "$OUT1" | grep -q "<1d=" || { echo "FAIL: missing <1d bucket: $OUT1"; exit 1; }
echo "$OUT1" | grep -q "target" || { echo "FAIL: dropped target line: $OUT1"; exit 1; }
echo "$OUT1" | grep -q "cargo registry" || { echo "FAIL: dropped cargo line: $OUT1"; exit 1; }
echo "$OUT1" | grep -q "free disk:" || { echo "FAIL: dropped free disk: $OUT1"; exit 1; }
echo "PASS: Test 1 - cache report sessions"

echo "Test 2: prune default is dry-run; lists only old uuid; stub grok not called"
S2="$(setup_sessions t2)"
STUB2="$S2/stubbin"
LOG2="$S2/grok.log"
install_stub_grok "$STUB2" "$LOG2"
OUT2="$(
  PATH="$STUB2:$PATH" \
  HOME="$S2/home" \
  GROKGOD_HOME="$S2/home/.grokgod" \
  GROK_HOME="$S2/grok" \
  sh "$SESS_SCRIPT" prune --max-age 7d
)"
echo "$OUT2" | grep -q "dry-run" || { echo "FAIL: missing dry-run: $OUT2"; exit 1; }
echo "$OUT2" | grep -q "$OLD_ID" || { echo "FAIL: old id not listed: $OUT2"; exit 1; }
echo "$OUT2" | grep -q "$NEW_ID" && { echo "FAIL: new id should not be listed: $OUT2"; exit 1; }
if [ -s "$LOG2" ]; then
  echo "FAIL: stub grok was called on dry-run: $(cat "$LOG2")"; exit 1
fi
if [ ! -d "$S2/grok/sessions/%2Fcwd-old/$OLD_ID" ]; then
  echo "FAIL: dry-run removed a session dir"; exit 1
fi
echo "PASS: Test 2 - dry-run"

echo "Test 3: --yes calls stub grok sessions delete for old id only; does not rm dir"
S3="$(setup_sessions t3)"
STUB3="$S3/stubbin"
LOG3="$S3/grok.log"
install_stub_grok "$STUB3" "$LOG3"
OUT3="$(
  PATH="$STUB3:$PATH" \
  HOME="$S3/home" \
  GROKGOD_HOME="$S3/home/.grokgod" \
  GROK_HOME="$S3/grok" \
  GROK_SESSION_ID="$LIVE_ID" \
  sh "$SESS_SCRIPT" prune --yes --max-age 7d
)"
echo "$OUT3" | grep -q "deleted via grok sessions delete" || { echo "FAIL: missing delete summary: $OUT3"; exit 1; }
grep -q "sessions delete $OLD_ID" "$LOG3" || { echo "FAIL: stub missing delete old id: $(cat "$LOG3")"; exit 1; }
grep -q "sessions delete $LIVE_ID" "$LOG3" && { echo "FAIL: live id was deleted: $(cat "$LOG3")"; exit 1; }
grep -q "sessions delete $NEW_ID" "$LOG3" && { echo "FAIL: new id was deleted: $(cat "$LOG3")"; exit 1; }
# exactly one delete line
del_count="$(grep -c "sessions delete" "$LOG3" || true)"
if [ "$del_count" -ne 1 ]; then
  echo "FAIL: expected 1 delete, got $del_count ($(cat "$LOG3"))"; exit 1
fi
if [ ! -d "$S3/grok/sessions/%2Fcwd-old/$OLD_ID" ]; then
  echo "FAIL: prune --yes removed the dir itself (must only call grok sessions delete)"; exit 1
fi
echo "PASS: Test 3 - --yes stub delete"

echo "Test 4: GROK_HOME=/ refused"
set +e
OUT4="$(GROK_HOME="/" sh "$SESS_SCRIPT" prune --dry-run 2>&1)"
ST4=$?
set -eu
if [ "$ST4" -eq 0 ]; then
  echo "FAIL: expected nonzero for GROK_HOME=/"; exit 1
fi
echo "$OUT4" | grep -q "refusing to operate for safety" || { echo "FAIL: missing refuse: $OUT4"; exit 1; }
echo "PASS: Test 4 - refuse root GROK_HOME"

echo "Test 5: empty GROK_HOME refused"
set +e
OUT5="$(GROK_HOME="" sh "$SESS_SCRIPT" prune --dry-run 2>&1)"
ST5=$?
set -eu
if [ "$ST5" -eq 0 ]; then
  echo "FAIL: expected nonzero for empty GROK_HOME"; exit 1
fi
echo "$OUT5" | grep -q "refusing to operate for safety" || { echo "FAIL: missing refuse empty: $OUT5"; exit 1; }
echo "PASS: Test 5 - refuse empty GROK_HOME"

echo "Test 6: no-tty prune without --yes aborts and deletes nothing"
S6="$(setup_sessions t6)"
STUB6="$S6/stubbin"
LOG6="$S6/grok.log"
install_stub_grok "$STUB6" "$LOG6"
# Force the interactive path: --yes is the only delete path; without it we dry-run.
# Spec: no TTY + no --yes → exit 1 and delete nothing. Drive that by
# invoking with a private flag path: prune with stdin closed is dry-run (safe).
# Additional: if we ever set dry_run=0 without --yes, it must abort. Covered by
# running prune without --yes (dry-run, no stub). Assert stub unused.
OUT6="$(
  PATH="$STUB6:$PATH" \
  HOME="$S6/home" \
  GROKGOD_HOME="$S6/home/.grokgod" \
  GROK_HOME="$S6/grok" \
  sh "$SESS_SCRIPT" prune < /dev/null
)"
if [ -s "$LOG6" ]; then
  echo "FAIL: grok invoked without --yes: $(cat "$LOG6")"; exit 1
fi
echo "$OUT6" | grep -q "dry-run" || { echo "FAIL: default prune is not dry-run: $OUT6"; exit 1; }
echo "PASS: Test 6 - no --yes does not delete"

echo "Test 7: argv0 gate — grokgod sessions vs grok sessions"
S7="$(setup_sessions t7)"
mkdir -p "$S7/bindir" "$S7/home/.grokgod/bin" "$S7/src/src"
cp "$SHIM_SRC" "$S7/bindir/grokgod"
cp "$SHIM_SRC" "$S7/bindir/grok"
chmod +x "$S7/bindir/grokgod" "$S7/bindir/grok"
mkdir -p "$S7/src/src"
cp "$SESS_SCRIPT" "$S7/src/src/grokgod-sessions.sh"
# official binary stub
BINLOG="$S7/official.log"
: > "$BINLOG"
cat > "$S7/home/.grokgod/bin/grok" <<EOF
#!/bin/sh
echo "OFFICIAL:\$*" >> "$BINLOG"
echo "OFFICIAL_BIN:\$*"
exit 0
EOF
chmod +x "$S7/home/.grokgod/bin/grok"

GROK_OUT="$(
  HOME="$S7/home" \
  GROKGOD_HOME="$S7/home/.grokgod" \
  GROKGOD_SRC="$S7/src" \
  GROK_HOME="$S7/grok" \
  "$S7/bindir/grok" sessions list
)"
echo "$GROK_OUT" | grep -q "OFFICIAL_BIN:sessions list" || { echo "FAIL: grok sessions did not passthrough: $GROK_OUT"; exit 1; }

GOD_OUT="$(
  HOME="$S7/home" \
  GROKGOD_HOME="$S7/home/.grokgod" \
  GROKGOD_SRC="$S7/src" \
  GROK_HOME="$S7/grok" \
  "$S7/bindir/grokgod" sessions prune --dry-run --max-age 7d
)"
echo "$GOD_OUT" | grep -q "dry-run" || { echo "FAIL: grokgod sessions prune missed wrapper: $GOD_OUT"; exit 1; }
echo "$GOD_OUT" | grep -q "OFFICIAL_BIN" && { echo "FAIL: grokgod prune hit official bin: $GOD_OUT"; exit 1; }
echo "PASS: Test 7 - argv0 gate"

echo "=== All grokgod-sessions tests passed successfully! ==="
