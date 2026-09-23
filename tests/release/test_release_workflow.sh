#!/bin/sh
set -eu

# test_release_workflow.sh: Verify release workflow invariants without network access or builds.
# Verifies:
# 1. Exact base commit pin sourcing (install.sh PINNED_BASE_SHA matches patches/README.md)
# 2. release.yml fetches and checks out exact PINNED_BASE_SHA and asserts HEAD equals it
# 3. compat-daily.yml remains untouched and tracks moving upstream origin/main
# 4. windows-x64 leg in release.yml is required (optional: false)
# 5. Version execution on built artifacts runs for every platform (including Windows) and fails on failure (no || true)
# 6. Checksum generation enforces exactly 1 checksum line matching the exact artifact name and fails if tooling is missing
# 7. Create Release requires grokgod-windows-x64.exe
# 8. Release creation is immutable: fails if release already exists, no --clobber

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
COMPAT_YML="$REPO_ROOT/.github/workflows/compat-daily.yml"
INSTALL_SH="$REPO_ROOT/install.sh"
PATCHES_README="$REPO_ROOT/patches/README.md"

echo "=== Running Release Workflow Invariant Tests ==="

# Test 1: install.sh PINNED_BASE_SHA matches patches/README.md and is exact target SHA
echo "Test 1: Single authoritative source pin"
PIN_SHA="$(grep '^PINNED_BASE_SHA=' "$INSTALL_SH" | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
if [ -z "$PIN_SHA" ]; then
  echo "FAIL: PINNED_BASE_SHA missing in $INSTALL_SH" >&2
  exit 1
fi
if [ "$PIN_SHA" != "07e35a3dfeed2f200d319ef6c893b5ea286d9a51" ]; then
  echo "FAIL: Expected PINNED_BASE_SHA to be 07e35a3dfeed2f200d319ef6c893b5ea286d9a51, got $PIN_SHA" >&2
  exit 1
fi
if ! grep -q "$PIN_SHA" "$PATCHES_README"; then
  echo "FAIL: $PIN_SHA not found in $PATCHES_README" >&2
  exit 1
fi
echo "PASS: Test 1"

# Test 2: release.yml fetches and checks out exact PINNED_BASE_SHA and asserts HEAD
echo "Test 2: release.yml checks out exact PINNED_BASE_SHA and asserts HEAD"
python3 -c "
import sys

with open('$RELEASE_YML', 'r') as f:
    content = f.read()

assert 'PINNED_BASE_SHA=' in content, 'release.yml missing PINNED_BASE_SHA lookup'
assert 'fetch --depth 1 origin \"\$PIN_SHA\"' in content, 'release.yml missing fetch of PIN_SHA'
assert 'checkout --detach \"\$PIN_SHA\"' in content, 'release.yml missing checkout of PIN_SHA'
assert 'actual_sha=\"\$(git -C grok-build rev-parse HEAD)\"' in content, 'release.yml missing HEAD rev-parse'
assert '\"\$actual_sha\" != \"\$PIN_SHA\"' in content, 'release.yml missing assertion that HEAD == PIN_SHA'
assert 'origin/main' not in content, 'release.yml should not target moving origin/main'
"
echo "PASS: Test 2"

# Test 3: compat-daily.yml remains tracking moving origin/main
echo "Test 3: compat-daily.yml continues tracking moving origin/main"
python3 -c "
with open('$COMPAT_YML', 'r') as f:
    content = f.read()

assert 'git clone --depth 1 https://github.com/xai-org/grok-build.git grok-build' in content, 'compat-daily must clone upstream'
assert 'origin/main' in content, 'compat-daily must reference origin/main'
guard = 'if [ \"\$pname\" = \"0001-normalize-plugin-skill-join.patch\" ]; then'
assert guard in content, 'manifest heuristic must be guarded to patch 0001'
assert 'fixed-upstream heuristic is patch-specific to 0001-normalize-plugin-skill-join.patch' in content, 'missing patch-specific fallback diagnostic'
assert 'upstream likely drifted/refactored; fixed-upstream heuristic is not applicable to \$pname' in content, 'other failures must report drift/refactor without fixed-upstream claim'
heuristic_start = content.index(guard)
heuristic_end = content.index('else\n                echo \"  note: upstream likely drifted/refactored;', heuristic_start)
heuristic = content[heuristic_start:heuristic_end]
assert 'Component::CurDir' in heuristic and 'fn normalize_path' in heuristic, '0001 heuristic must retain CurDir/normalize_path checks'
"
echo "PASS: Test 3"
echo "PASS: Test 3b (compat-daily fixed-upstream diagnostic is patch-specific)"

# Test 4: windows-x64 is required in release.yml matrix (optional: false)
echo "Test 4: windows-x64 required leg in release matrix"
python3 -c "
import yaml

with open('$RELEASE_YML', 'r') as f:
    data = yaml.safe_load(f)

matrix_legs = data['jobs']['build']['strategy']['matrix']['include']
windows_legs = [leg for leg in matrix_legs if leg.get('target') == 'windows-x64']
assert len(windows_legs) == 1, f'Expected exactly 1 windows-x64 leg, found {len(windows_legs)}'
win = windows_legs[0]
assert win.get('optional') is False, f'windows-x64 optional must be False, got {win.get(\"optional\")}'
assert win.get('os') == 'windows-latest', f'Expected windows-latest, got {win.get(\"os\")}'
assert win.get('ext') == '.exe', f'Expected .exe ext, got {win.get(\"ext\")}'
"
echo "PASS: Test 4"

# Test 5: Every packaged artifact executed with --version and fails on error (no || true, no OS bypass)
echo "Test 5: Version verification executed for all artifacts without || true"
python3 -c "
with open('$RELEASE_YML', 'r') as f:
    content = f.read()

assert '\"\$BIN_DST\" --version' in content, 'Missing \"\$BIN_DST\" --version step'
assert '\"\$BIN_DST\" --version || true' not in content, 'Found forbidden \"|| true\" on version verification'
assert '\"\$BIN_DST\" --version ||' not in content, 'Found fallback on version verification'
assert 'runner.os != \'Windows\'' not in content and 'runner.os != \"Windows\"' not in content, 'Found Windows bypass on version verification'
"
echo "PASS: Test 5"

# Test 6: Checksum tooling failure and format validation
echo "Test 6: Checksum generation format and fail-closed tooling check"
python3 -c "
with open('$RELEASE_YML', 'r') as f:
    content = f.read()

assert 'Neither sha256sum nor shasum is available' in content, 'Missing fail-closed checksum tooling check'
assert 'Expected exactly 1 checksum line' in content, 'Missing single checksum line assertion'
assert 'Checksum line in' in content and 'does not match expected artifact name' in content, 'Missing checksum filename assertion'
assert content.count('awk -v expected=') >= 2, 'Missing exact checksum-field parsers'
assert 'matches == 1' in content, 'Checksum parser must require one exact filename match'
assert 'sub(/^' in content and '"", name)' in content, 'Missing checksum marker normalization'
"

# Test 6b: Simulation of checksum verification logic in bash
TMP_SIM="$(mktemp -d)"
(
  cd "$TMP_SIM"
  echo "dummy binary" > grokgod-windows-x64.exe
  artifact="grokgod-windows-x64.exe"
  checksum_file="SHA256SUMS-windows-x64"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$artifact" > "$checksum_file"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$artifact" > "$checksum_file"
  else
    exit 1
  fi

  validate_single_checksum() {
    candidate_file="$1"
    expected="$2"
    num_lines="$(wc -l < "$candidate_file" | tr -d '[:space:]')"
    test "$num_lines" -eq 1 || return 1
    awk -v expected="$expected" '
      NF == 2 {
        name = $2
        sub(/^\*/, "", name)
        if (name == expected) matches++
      }
      END { exit matches == 1 ? 0 : 1 }
    ' "$candidate_file"
  }

  validate_single_checksum "$checksum_file" "$artifact"

  hash="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  printf '%s  %s\n' "$hash" "$artifact" > "$checksum_file"
  validate_single_checksum "$checksum_file" "$artifact"

  printf '%s *%s\n' "$hash" "$artifact" > "$checksum_file"
  validate_single_checksum "$checksum_file" "$artifact"

  printf '%s *%s.bak\n' "$hash" "$artifact" > "$checksum_file"
  if validate_single_checksum "$checksum_file" "$artifact"; then
    echo "FAIL: accepted a near-match checksum filename"
    exit 1
  fi

  printf '%s *%s extra\n' "$hash" "$artifact" > "$checksum_file"
  if validate_single_checksum "$checksum_file" "$artifact"; then
    echo "FAIL: accepted an extra checksum field"
    exit 1
  fi

  printf '%s *%s\n%s *other.exe\n' "$hash" "$artifact" "$hash" > "$checksum_file"
  if validate_single_checksum "$checksum_file" "$artifact"; then
    echo "FAIL: accepted multiple checksum lines"
    exit 1
  fi
)
rm -rf "$TMP_SIM"
echo "PASS: Test 6"

# Test 7: Create Release requires grokgod-windows-x64.exe and Windows runtime assets
echo "Test 7: Create Release requires grokgod-windows-x64.exe and Windows runtime assets"
python3 -c "
with open('$RELEASE_YML', 'r') as f:
    content = f.read()

assert 'release-assets/grokgod-windows-x64.exe' in content, 'Create Release missing grokgod-windows-x64.exe asset check'
assert 'grok-shim.ps1' in content, 'release.yml missing grok-shim.ps1 runtime asset'
assert 'LauncherHelpers.ps1' in content, 'release.yml missing LauncherHelpers.ps1 runtime asset'
assert 'install.ps1' in content, 'release.yml missing install.ps1 runtime asset'
assert 'release-assets/\$runtime' in content, 'release.yml missing runtime asset existence check'
assert 'SHA256SUMS' in content, 'release.yml missing SHA256SUMS check'
assert 'sort SHA256SUMS -o SHA256SUMS' in content, 'Release assembly must preserve duplicate checksum entries for validation'
assert 'sort -u SHA256SUMS' not in content, 'Release assembly must not erase duplicate checksum evidence'
"
echo "PASS: Test 7"

# Test 8: Immutable release publication: fails if tag exists, no --clobber
echo "Test 8: Immutable release publication"
python3 -c "
with open('$RELEASE_YML', 'r') as f:
    content = f.read()

assert '--clobber' not in content, 'Found forbidden --clobber in release.yml'
assert 'gh release upload' not in content, 'Found forbidden gh release upload in release.yml'
assert 'gh release view \"\$tag\"' in content, 'Missing gh release view existence check'
assert 'immutable release policy forbids mutating or clobbering' in content, 'Missing immutable release error guard'
assert 'gh release create \"\$tag\"' in content, 'Missing gh release create'
"
echo "PASS: Test 8"

echo "=== All Release Workflow Invariant Tests Passed Successfully! ==="
