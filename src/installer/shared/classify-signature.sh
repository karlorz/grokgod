#@build:strip-header
# Canonical codesign signature classifier.
#
# Compiled into install.sh and src/shim/grok-shim.sh by src/installer/build.mjs.
# Those two copies were already identical in behavior and differed only in the
# callable name and the local variable spellings. The marker injects the name
# each caller used before this file existed, so the generated installers keep
# their original spelling; the body uses one pair of generic locals.
#
# Do not edit a generated installer to change this behavior. Edit this file and
# run: node src/installer/build.mjs
#@build:end-header
{{GROKGOD:functionName}}() {
  _sig_path="${1:-}"
  if [ -z "$_sig_path" ] || [ ! -e "$_sig_path" ]; then
    printf 'absent'
    return 0
  fi
  if [ "$(uname -s 2>/dev/null || true)" != "Darwin" ] || ! command -v codesign >/dev/null 2>&1; then
    printf 'unsupported'
    return 0
  fi
  _sig_out="$(codesign -dv "$_sig_path" 2>&1 || true)"
  case "$_sig_out" in
    *"code object is not signed at all"*) printf 'unsigned' ;;
    *"Signature=adhoc"*) printf 'adhoc' ;;
    *"Authority="*) printf 'signed' ;;
    *) printf 'unknown' ;;
  esac
  return 0
}
