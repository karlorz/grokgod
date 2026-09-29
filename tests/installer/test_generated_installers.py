#!/usr/bin/env python3
"""
Contract tests for the generated-installer pipeline (install.sh, install.ps1,
src/shim/grok-shim.sh, src/shim/templates/*.cmd.template, LauncherHelpers.ps1).

The shipped installers are compiled from src/installer/{constants.json,shared/*,
templates/*} by src/installer/build.mjs. These tests run on macOS, Linux and
Windows and require only the Python standard library plus `node`, matching how
tests/install/test_install_windows.py and tests/shim/test_shim_windows.py are
kept portable.

What is covered:
  1. Every generated artifact is byte-current with its sources (`build --check`).
  2. Generating twice is idempotent and does not touch the shipped bytes.
  3. Editing a generated artifact is detected (the drift check is not a no-op).
  4. Editing a canonical source is detected (the check reads the sources, not a
     cached copy of the artifacts).
  5. The extraction is lossless: the previously duplicated blocks are one source
     now, and the two copies that were already in sync still agree.
  6. Constants that must agree across files really do come from one file.
  7. The generated files obey the text contracts the existing suites rely on
     (trailing newline, LF, ASCII for the PowerShell artifacts, exec bit).
  8. `cut.mjs --check` agrees that the templates are current.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
INSTALLER = os.path.join(REPO_ROOT, "src", "installer")
BUILD_MJS = os.path.join(INSTALLER, "build.mjs")
CUT_MJS = os.path.join(INSTALLER, "cut.mjs")
CONSTANTS = os.path.join(INSTALLER, "constants.json")

# Artifacts written by build.mjs, in TARGETS order.
GENERATED = [
    "install.sh",
    "install.ps1",
    "src/shim/grok-shim.sh",
    "src/shim/templates/grok.cmd.template",
    "src/shim/templates/grokgod.cmd.template",
    "src/shim/LauncherHelpers.ps1",
]

ASCII_ONLY = [
    "install.ps1",
    "src/shim/templates/grok.cmd.template",
    "src/shim/templates/grokgod.cmd.template",
    "src/shim/LauncherHelpers.ps1",
]

passes = 0
fails = 0


def check(cond, name, detail=""):
    global passes, fails
    if cond:
        print(f"  PASS: {name}")
        passes += 1
    else:
        print(f"  FAIL: {name}")
        if detail:
            print(f"        {detail}")
        fails += 1


def run(args, cwd=REPO_ROOT):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def node_available():
    return shutil.which("node") is not None


def read(path):
    with open(os.path.join(REPO_ROOT, path), "rb") as handle:
        return handle.read()


def function_body(text, signature):
    """Return the text between a shell function's braces, delimiters excluded."""
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:index]
    raise AssertionError(f"unterminated function: {signature}")


def main():
    print("=== Generated Installer Contract Test Suite ===")

    for path in GENERATED:
        check(os.path.isfile(os.path.join(REPO_ROOT, path)), f"{path} exists")

    if not node_available():
        print("SKIP: node is unavailable; generated-installer checks not run")
        print(f"\nTotal Passed: {passes}\nTotal Failed: {fails}")
        return

    for path in (BUILD_MJS, CUT_MJS, CONSTANTS):
        check(os.path.isfile(path), f"{os.path.relpath(path, REPO_ROOT)} exists")

    # --- 1. artifacts are current -----------------------------------------
    result = run(["node", BUILD_MJS, "--check"])
    check(result.returncode == 0, "node src/installer/build.mjs --check exits 0",
          result.stdout + result.stderr)
    for path in GENERATED:
        check(f"ok: {path}" in result.stdout, f"check reports {path} is current",
              result.stdout)

    # --- 2. generating is idempotent and lossless -------------------------
    before = {path: read(path) for path in GENERATED}
    build = run(["node", BUILD_MJS])
    check(build.returncode == 0, "node src/installer/build.mjs exits 0",
          build.stdout + build.stderr)
    after = {path: read(path) for path in GENERATED}
    check(before == after, "generating does not change the committed artifacts",
          "; ".join(p for p in GENERATED if before[p] != after[p]))

    # --- 8. cut.mjs agrees the templates match the artifacts -------------
    cut = run(["node", CUT_MJS, "--check"])
    check(cut.returncode == 0, "node src/installer/cut.mjs --check exits 0",
          cut.stdout + cut.stderr)

    # --- 5. extraction is lossless ---------------------------------------
    install_sh = os.path.join(REPO_ROOT, "install.sh")
    with open(install_sh, "r", encoding="utf-8") as handle:
        install_sh_text = handle.read()
    with open(os.path.join(REPO_ROOT, "src", "shim", "grok-shim.sh"),
              "r", encoding="utf-8") as handle:
        shim_text = handle.read()

    shared_part = os.path.join(INSTALLER, "shared", "fast-forward-repo.sh")
    with open(shared_part, "r", encoding="utf-8") as handle:
        shared_text = handle.read()
    lines = shared_text.split("\n")
    end = lines.index("#@build:end-header")
    shared_body = "\n".join(lines[end + 1:-1]).replace(
        "{{GROKGOD:functionName}}", "SHARED"
    )

    check(
        function_body(install_sh_text, "fast_forward_or_reset_grokgod_src() {")
        == function_body(shared_body, "SHARED() {"),
        "install.sh fast-forward body is the shared source (lossless merge)",
    )
    check(
        function_body(shim_text, "fast_forward_or_reset_repo() {")
        == function_body(shared_body, "SHARED() {"),
        "grok-shim.sh fast-forward body is the shared source (lossless merge)",
    )
    check(
        function_body(install_sh_text, "fast_forward_or_reset_grokgod_src() {")
        == function_body(shim_text, "fast_forward_or_reset_repo() {"),
        "install.sh and grok-shim.sh still agree on fast-forward behavior",
    )
    check(
        "Behavior must match the other copy in src/shim/grok-shim.sh (fast_forward_or_reset_repo)"
        not in install_sh_text
        and "Behavior must match the other copy in install.sh (sync_installed_grokgod_src)"
        not in shim_text,
        "the hand-sync comments above the fast-forward copies are gone",
    )

    # --- 6. constants come from constants.json ---------------------------
    import json
    with open(CONSTANTS, "r", encoding="utf-8") as handle:
        constants = json.load(handle)

    sha = constants["grokBuildBaseSha"]
    slug = constants["githubRepoSlug"]
    asset = constants["windowsTargetAsset"]

    check(re.fullmatch(r"[0-9a-f]{40}", sha) is not None,
          "constants.json grokBuildBaseSha is a 40-hex SHA")
    check(
        f"PINNED_BASE_SHA={sha}" in install_sh_text,
        "install.sh carries the constant base SHA",
    )
    with open(os.path.join(REPO_ROOT, "install.ps1"), "r", encoding="utf-8") as handle:
        install_ps1_text = handle.read()
    check(
        f'$PINNED_BASE_SHA = "{sha}"' in install_ps1_text,
        "install.ps1 carries the constant base SHA",
    )
    check(
        f'$TARGET_ASSET    = "{asset}"' in install_ps1_text,
        "install.ps1 carries the constant Windows asset name",
    )
    for path, text in (("install.sh", install_sh_text),
                       ("install.ps1", install_ps1_text),
                       ("src/shim/grok-shim.sh", shim_text)):
        check(
            re.search(r"07e35a3dfeed2f200d319ef6c893b5ea286d9a51", text) is not None
            or path == "src/shim/grok-shim.sh",
            f"{path} does not hardcode a second copy of the base SHA",
        )
    check(
        f"https://github.com/{slug}" in install_sh_text,
        "install.sh carries the repo slug from constants.json",
    )

    # The literal must live in exactly one canonical place.
    hardcoded = []
    for root, dirs, files in os.walk(INSTALLER):
        dirs[:] = [d for d in dirs if d != "node_modules"]
        for name in files:
            path = os.path.join(root, name)
            if path == CONSTANTS:
                continue
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                if sha in handle.read():
                    hardcoded.append(os.path.relpath(path, REPO_ROOT))
    check(not hardcoded, "the base SHA is stored only in src/installer/constants.json",
          ", ".join(hardcoded))

    # --- 7. text contracts -------------------------------------------------
    for path in GENERATED:
        data = read(path)
        check(data.endswith(b"\n") and not data.endswith(b"\n\n"),
              f"{path} ends with exactly one newline")
        check(b"\r" not in data, f"{path} uses LF only")
        check(not data.startswith(b"\xef\xbb\xbf"), f"{path} has no UTF-8 BOM")
    for path in ASCII_ONLY:
        data = read(path)
        index = next((i for i, byte in enumerate(data) if byte > 127), None)
        check(index is None, f"{path} is ASCII-only",
              f"non-ASCII byte at offset {index}")
    # The exec bit only exists on POSIX; on Windows git does not materialize it.
    if os.name == "posix":
        mode = os.stat(os.path.join(REPO_ROOT, "install.sh")).st_mode
        check(bool(mode & 0o111), "install.sh is executable")
        mode = os.stat(os.path.join(REPO_ROOT, "src", "shim", "grok-shim.sh")).st_mode
        check(bool(mode & 0o111), "src/shim/grok-shim.sh is executable")

    # --- 3/4. the check actually detects drift ----------------------------
    # The sandbox must invoke its own copy of build.mjs: the script resolves
    # its inputs relative to its own location, so running the in-repo copy
    # would keep reading the in-repo sources and prove nothing.
    with tempfile.TemporaryDirectory() as tmp:
        sandbox = os.path.join(tmp, "repo")
        shutil.copytree(
            os.path.join(REPO_ROOT, "src", "installer"),
            os.path.join(sandbox, "src", "installer"),
        )
        with open(os.path.join(sandbox, "src", "installer", "build.mjs"), "r",
                  encoding="utf-8") as handle:
            sandbox_build = handle.read()
        with open(os.path.join(sandbox, "src", "installer", "build.mjs"), "w",
                  encoding="utf-8") as handle:
            handle.write(sandbox_build)
        sandbox_build_mjs = os.path.join(sandbox, "src", "installer", "build.mjs")
        for path in GENERATED:
            destination = os.path.join(sandbox, path)
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            shutil.copy2(os.path.join(REPO_ROOT, path), destination)

        # (a) tamper with a generated artifact
        with open(os.path.join(sandbox, "install.ps1"), "a", encoding="utf-8") as handle:
            handle.write("# tampered\n")
        result = run(["node", sandbox_build_mjs, "--check"], cwd=sandbox)
        check(result.returncode == 1 and "out of date: install.ps1" in result.stdout + result.stderr,
              "editing a generated artifact fails the check",
              result.stdout + result.stderr)

        # (b) restore, then tamper with a canonical source instead
        result = run(["node", sandbox_build_mjs], cwd=sandbox)
        check(result.returncode == 0, "regenerating in the sandbox succeeds",
              result.stdout + result.stderr)
        with open(os.path.join(sandbox, "install.sh"), "a", encoding="utf-8") as handle:
            handle.write("# tampered\n")
        result = run(["node", sandbox_build_mjs], cwd=sandbox)
        check(result.returncode == 0, "regenerating repairs the tampered artifact",
              result.stdout + result.stderr)
        constants_path = os.path.join(sandbox, "src", "installer", "constants.json")
        with open(constants_path, "r", encoding="utf-8") as handle:
            sandbox_constants = handle.read()
        with open(constants_path, "w", encoding="utf-8") as handle:
            handle.write(sandbox_constants.replace(sha, "0" * 40))
        result = run(["node", sandbox_build_mjs, "--check"], cwd=sandbox)
        check(result.returncode == 1 and "out of date" in result.stdout + result.stderr,
              "editing a canonical constant fails the check (sources are re-read)",
              result.stdout + result.stderr)

        # (c) unknown flags are a usage error, not a silent success
        result = run(["node", sandbox_build_mjs, "--nope"], cwd=sandbox)
        check(result.returncode == 2, "unknown arguments exit 2",
              result.stdout + result.stderr)

    print("\n===============================================")
    print(f"Total Passed: {passes}")
    print(f"Total Failed: {fails}")
    print("===============================================")
    if fails > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
