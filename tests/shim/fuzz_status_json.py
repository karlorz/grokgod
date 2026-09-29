#!/usr/bin/env python3
"""Hostile-input fuzz for `grok-shim.sh status --json`.

Runs the shim against generated stamps/manifests in an isolated HOME and
asserts the JSON contract that the POSIX status feature promises:
  - stdout is a single line of valid JSON (utf-8 decodable)
  - stderr is empty in every state
  - the exit code is always one of 0/1/2 and matches `health`
Every case runs under both `sh` and `dash` (when present).

Usage: python3 tests/shim/fuzz_status_json.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHIM = os.path.join(REPO_ROOT, "src", "shim", "grok-shim.sh")

HEX = "0123456789abcdef" * 4  # 64 chars
BINARY = b"#!/bin/sh\necho fuzz\n"

STAMPS = {
    "lf": b"SHA=%s\nPATCHSET=v1\nVERSION=v1\nMODE=release\n" % HEX.encode(),
    "crlf": b"SHA=%s\r\nPATCHSET=v1\r\nVERSION=v1\r\nMODE=release\r\n" % HEX.encode(),
    "no-trailing-newline": b"SHA=%s\nPATCHSET=v1\nVERSION=v1\nMODE=release" % HEX.encode(),
    "empty": b"",
    "no-sha": b"MODE=release\nVERSION=v1\n",
    "duplicate-sha": b"SHA=%s\nSHA=%s\nPATCHSET=v1\nMODE=release\n" % (HEX.encode(), HEX.encode()),
    "duplicate-mode": b"SHA=%s\nMODE=release\nMODE=source\n" % HEX.encode(),
    "uppercase-sha": b"SHA=%s\nMODE=release\n" % HEX.upper().encode(),
    "binary-bytes": b"SHA=%s\nMODE=release\nVERSION=\xff\xfe\x00\x01\n" % HEX.encode(),
    "invalid-utf8": b"SHA=%s\nMODE=release\nVERSION=caf\xe9\n" % HEX.encode(),
    "valid-utf8": "SHA=%s\nMODE=release\nVERSION=café🎉\n".encode("utf-8") % HEX.encode(),
    "quotes-and-backslashes": b'SHA=%s\nMODE=release\nVERSION=a"b\\c\\"d\n' % HEX.encode(),
    "huge-value": b"SHA=%s\nMODE=release\nVERSION=%s\n" % (HEX.encode(), b"x" * 20000),
    "only-separators": b"======\n===\n",
    "nul-free-controls": b"SHA=%s\nMODE=release\nVERSION=a\x01b\x02c\x1fd\x7fe\n" % HEX.encode(),
}

MANIFESTS = {
    "absent": None,
    "empty": b"",
    "truncated": b'{"formatVersion": 1,',
    "garbage": b"not json at all\n",
    "braces-only": b"{\n}\n",
    "no-platform": b'{\n  "formatVersion": 1,\n  "artifactSha256": "%s"\n}\n' % HEX.encode(),
    "windows-style": b'{\n  "formatVersion": 1,\n  "artifactSha256": "%s",\n  "mode": "release"\n}\n' % HEX.encode(),
    "missing-comma": b'{\n  "formatVersion": 1\n  "platform": "posix",\n  "artifactSha256": "%s"\n}\n' % HEX.encode(),
    "trailing-comma": b'{\n  "formatVersion": 1,\n  "platform": "posix",\n  "artifactSha256": "%s",\n}\n' % HEX.encode(),
    "empty-hash": b'{\n  "formatVersion": 1,\n  "platform": "posix",\n  "artifactSha256": ""\n}\n',
    "short-hash": b'{\n  "formatVersion": 1,\n  "platform": "posix",\n  "artifactSha256": "abc"\n}\n',
    "duplicate-hash": b'{\n  "formatVersion": 1,\n  "platform": "posix",\n  "artifactSha256": "%s",\n  "artifactSha256": "%s"\n}\n' % (HEX.encode(), HEX.encode()),
    "wrong-format-version": b'{\n  "formatVersion": 2,\n  "platform": "posix",\n  "artifactSha256": "%s"\n}\n' % HEX.encode(),
    "hostile-strings": b'{\n  "formatVersion": 1,\n  "platform": "posix",\n  "artifactSha256": "%s",\n  "mode": "\\u0000\\u001f",\n  "note": "tab\\there \\"quoted\\" back\\\\slash"\n}\n' % HEX.encode(),
}

BINARIES = {
    "present": BINARY,
    "absent": None,
    "directory": "DIR",
    "symlink-loop": "LOOP",
    "unreadable": "CHMOD000",
}


def build_home(root, stamp_bytes, manifest_bytes, binary_kind):
    home = os.path.join(root, "home")
    gh = os.path.join(home, ".grokgod")
    os.makedirs(os.path.join(gh, "bin"), exist_ok=True)
    os.makedirs(os.path.join(home, ".local", "bin"), exist_ok=True)
    with open(os.path.join(home, ".local", "bin", "grok"), "w") as fh:
        fh.write("# GROKGOD shim\n")
    bin_path = os.path.join(gh, "bin", "grok")
    if binary_kind == "present":
        with open(bin_path, "wb") as fh:
            fh.write(BINARY)
        os.chmod(bin_path, 0o755)
    elif binary_kind == "directory":
        os.makedirs(bin_path, exist_ok=True)
    elif binary_kind == "symlink-loop":
        os.symlink(bin_path, bin_path)
    elif binary_kind == "unreadable":
        with open(bin_path, "wb") as fh:
            fh.write(BINARY)
        os.chmod(bin_path, 0o000)
    if stamp_bytes is not None:
        with open(os.path.join(gh, ".source-version"), "wb") as fh:
            fh.write(stamp_bytes)
    if manifest_bytes is not None:
        with open(os.path.join(gh, "manifest.json"), "wb") as fh:
            fh.write(manifest_bytes)
    return home, gh


def run_case(shell, home, gh, root):
    env = {
        "HOME": home,
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "GROKGOD_HOME": gh,
        "GROKGOD_SRC": os.path.join(root, "src"),
        "GROK_BUILD_SRC": os.path.join(root, "nonexistent"),
        "GROKGOD_UPDATE_CHECK_DISABLE": "1",
    }
    proc = subprocess.run(
        [shell, SHIM, "status", "--json"],
        env=env, capture_output=True, cwd=REPO_ROOT,
    )
    problems = []
    if proc.stderr:
        problems.append("stderr not empty: %r" % proc.stderr[:120])
    try:
        text = proc.stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        problems.append("stdout is not valid UTF-8: %s" % exc)
        return problems
    if text.count("\n") != 1 or not text.endswith("\n"):
        problems.append("stdout is not exactly one line: %r" % text[:120])
    try:
        doc = json.loads(text)
    except Exception as exc:  # noqa: BLE001
        problems.append("stdout is not valid JSON: %s" % exc)
        return problems
    health = doc.get("health")
    expected = {"healthy": 0, "degraded": 1, "corrupt": 2}.get(health)
    if expected is None:
        problems.append("unknown health %r" % health)
    elif proc.returncode != expected:
        problems.append("exit %d does not match health %r (expected %d)" % (proc.returncode, health, expected))
    if not isinstance(doc.get("healthDetails"), list):
        problems.append("healthDetails is not an array")
    for key in ("mode", "version", "patchset", "sourceSha", "artifactSha256", "computedSha256"):
        if key not in doc:
            problems.append("missing key %s" % key)
    return problems


def main():
    if not os.path.isfile(SHIM):
        print("FAIL: shim not found at %s" % SHIM)
        return 1
    shells = ["sh"]
    if shutil.which("dash"):
        shells.append("dash")

    failures = 0
    cases = 0
    for stamp_name, stamp in STAMPS.items():
        for manifest_name, manifest in MANIFESTS.items():
            for binary_name, binary in BINARIES.items():
                for shell in shells:
                    root = tempfile.mkdtemp(prefix="grokgod-fuzz-")
                    try:
                        home, gh = build_home(root, stamp, manifest, binary)
                        label = "%s/%s/%s/%s" % (stamp_name, manifest_name, binary_name, os.path.basename(shell))
                        problems = run_case(shell, home, gh, root)
                        cases += 1
                        if problems:
                            failures += 1
                            print("FAIL %s" % label)
                            for problem in problems:
                                print("     %s" % problem)
                    finally:
                        for dirpath, dirnames, filenames in os.walk(root):
                            os.chmod(dirpath, 0o755)
                            for name in filenames:
                                try:
                                    os.chmod(os.path.join(dirpath, name), 0o644)
                                except OSError:
                                    pass
                        shutil.rmtree(root, ignore_errors=True)
    print("\nfuzz cases: %d, failures: %d" % (cases, failures))
    if failures:
        print("=== fuzz_status_json FAILED ===")
        return 1
    print("=== fuzz_status_json PASSED ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
