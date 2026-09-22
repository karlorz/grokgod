#!/bin/sh
set -eu

# grokgod-eval-health.sh — one-shot Minimal-agent health probe (text + native vision).
# Wrapper on top of grokgod-eval.sh; not a grok-build source patch.
# The Orca eval automation calls this with the target model as the only argument,
# so the model can be switched from the Orca UI prompt field or the CLI.

GROKGOD_HOME="${GROKGOD_HOME:-$HOME/.grokgod}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
EVAL_WRAPPER="$SCRIPT_DIR/grokgod-eval.sh"
EVAL_HOME="${GROKGOD_EVAL_HOME:-$GROKGOD_HOME/eval-home}"
PROBE_IMAGE="$EVAL_HOME/assets/vision-probe.jpg"
HEALTH_DIR="$EVAL_HOME/health"
DAILY_CONFIG="${GROK_DAILY_CONFIG:-$HOME/.grok/config.toml}"
MODEL="deepseek-v4-flash"
DRY_RUN=0

usage() {
  cat << 'EOF' >&2
Usage:
  grokgod eval-health [--dry-run] [--model ID]

Run a Minimal-agent health probe against one model: a text ping and a native
vision transcription of examples/eval-home/assets/vision-probe.jpg. Prints one
EVAL_HEALTH JSON line; exit 0 when both probes pass, 1 otherwise. The vision
result is also persisted (redacted) to <EVAL_HOME>/health/vision.json plus a
timestamped sibling.

Options:
  --dry-run   Print model, auth source, and probe paths; do not call the model
  --model ID  Model id (default: deepseek-v4-flash; positional arg also works)
  -h, --help  Show this help

Auth: CLIAPI_API_KEY or NEW_API_KEY from the environment. When neither is set,
the inline api_key for the model is read from the daily ~/.grok/config.toml at
runtime (never copied into the eval home). No secrets are printed.
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --model)
      [ $# -ge 2 ] || { echo "error: --model requires an id" >&2; exit 1; }
      MODEL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "error: unrecognized option '$1'" >&2
      usage
      ;;
    *)
      MODEL="$1"
      shift
      ;;
  esac
done

if [ ! -f "$EVAL_WRAPPER" ]; then
  echo "error: eval wrapper missing: $EVAL_WRAPPER" >&2
  echo "hint: reinstall with install.sh --from-source --no-upgrade" >&2
  exit 1
fi

# Auth: env first, then the daily config's inline api_key for this model.
AUTH_SOURCE="env"
if [ -z "${CLIAPI_API_KEY:-}" ] && [ -z "${NEW_API_KEY:-}" ]; then
  AUTH_SOURCE="config"
  _key=""
  if [ -f "$DAILY_CONFIG" ]; then
    _key=$(awk -v m="$MODEL" '
      $0 == "[model." m "]" || $0 == "[model.\"" m "\"]" { in_sec=1; next }
      /^\[/ { in_sec=0 }
      in_sec && /^api_key[[:space:]]*=/ {
        line=$0
        sub(/^api_key[[:space:]]*=[[:space:]]*"/, "", line)
        sub(/"[[:space:]]*$/, "", line)
        print line
        exit
      }
    ' "$DAILY_CONFIG")
  fi
  if [ -n "$_key" ]; then
    NEW_API_KEY="$_key"
    export NEW_API_KEY
  else
    echo "error: no CLIAPI_API_KEY/NEW_API_KEY in env and no inline api_key for [model.$MODEL] in $DAILY_CONFIG" >&2
    exit 1
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "MODEL=$MODEL"
  echo "AUTH_SOURCE=$AUTH_SOURCE"
  echo "EVAL_HOME=$EVAL_HOME"
  echo "PROBE_IMAGE=$PROBE_IMAGE"
  echo "EVAL_WRAPPER=$EVAL_WRAPPER"
  exit 0
fi

if [ ! -f "$PROBE_IMAGE" ]; then
  echo "error: vision probe image missing: $PROBE_IMAGE" >&2
  echo "hint: run 'grokgod eval --reset' to re-seed the eval home" >&2
  exit 1
fi

TMPDIR_PROBE="$(mktemp -d "${TMPDIR:-/tmp}/grokgod-eval-health.XXXXXX")"
trap 'rm -rf "$TMPDIR_PROBE"' EXIT

run_probe() {
  # $1 prompt file, $2 max turns, $3 output json path
  if sh "$EVAL_WRAPPER" --model "$MODEL" -- \
      --prompt-file "$1" --output-format json --max-turns "$2" \
      > "$3" 2> "$3.err"; then
    return 0
  fi
  return 1
}

printf 'Reply with exactly: PONG' > "$TMPDIR_PROBE/text.txt"
TEXT_OK=0
if run_probe "$TMPDIR_PROBE/text.txt" 1 "$TMPDIR_PROBE/text.json"; then
  TEXT_OK=1
fi

_b64=$(base64 < "$PROBE_IMAGE" | tr -d '\n')
printf '%s' "{\"type\":\"acp\",\"content\":[{\"type\":\"text\",\"text\":\"Minimal eval. Transcribe every visible label in the attached image verbatim. Answer with the visible names and short descriptions only. Do not use tools. Do not call external APIs. Do not mention POE.\"},{\"type\":\"image\",\"mimeType\":\"image/jpeg\",\"data\":\"$_b64\"}]}" \
  > "$TMPDIR_PROBE/vision.json"
VISION_OK=0
if run_probe "$TMPDIR_PROBE/vision.json" 2 "$TMPDIR_PROBE/vision.out.json"; then
  VISION_OK=1
fi

TEXT_JSON="$TMPDIR_PROBE/text.json"
VISION_JSON="$TMPDIR_PROBE/vision.out.json"
[ -f "$TEXT_JSON" ] || printf '{}' > "$TEXT_JSON"
[ -f "$VISION_JSON" ] || printf '{}' > "$VISION_JSON"

# Secrets travel through the environment, never argv (argv is world-readable).
CLIAPI_API_KEY="${CLIAPI_API_KEY:-}" NEW_API_KEY="${NEW_API_KEY:-}" \
python3 - "$MODEL" "$TEXT_OK" "$VISION_OK" "$TEXT_JSON" "$VISION_JSON" "$HEALTH_DIR" << 'PYEOF'
import json, os, re, sys
from datetime import datetime, timezone

model, text_rc, vision_rc = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
health_dir = sys.argv[6]

SK_RE = re.compile(r"sk-[A-Za-z0-9_-]{4,}")
SECRETS = [v for v in (os.environ.get("CLIAPI_API_KEY"), os.environ.get("NEW_API_KEY")) if v]

def redact(s):
    s = SK_RE.sub("[REDACTED]", s)
    for sec in SECRETS:
        s = s.replace(sec, "[REDACTED]")
    return s

def maybe_redact(v):
    return redact(v) if isinstance(v, str) else v

def or_null(v):
    # Schema: string or null. Redact when it is a string.
    return redact(v) if isinstance(v, str) and v else None

def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        return {}

def reply(d):
    return d.get("text") or d.get("reply") or ""

def stop(d):
    return d.get("stopReason") or d.get("stop_reason")

def session(d):
    return d.get("sessionId") or d.get("session_id")

t, v = load(sys.argv[4]), load(sys.argv[5])
ttext, vtext = reply(t), reply(v)
t_ok = text_rc and "PONG" in ttext
v_ok = vision_rc and "agent" in vtext.lower()

# Durable record of the vision probe: parsed fields only, redacted, no stderr
# and no daily config content.
record = {
    "kind": "grokgod-eval-vision",
    "model": redact(model),
    "sessionId": or_null(session(v)),
    "stopReason": or_null(stop(v)),
    "text": redact(vtext),
    "ok": v_ok,
}
latest = os.path.join(health_dir, "vision.json")
try:
    os.makedirs(health_dir, exist_ok=True)
    for path in (latest,
                 os.path.join(health_dir, "vision-%s.json" % datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))):
        with open(path, "w") as f:
            json.dump(record, f, ensure_ascii=False)
            f.write("\n")
except Exception as exc:
    sys.stderr.write("error: cannot write vision result %s: %s\n" % (latest, exc))
    sys.exit(1)

summary = {
    "model": redact(model),
    "text": {"ok": t_ok, "reply": redact(ttext)[:120], "turns": t.get("num_turns"), "stop": maybe_redact(stop(t))},
    "vision": {"ok": v_ok, "reply": redact(vtext)[:160], "turns": v.get("num_turns"),
               "stop": maybe_redact(stop(v))},
}
summary["ok"] = bool(t_ok and v_ok)
print("EVAL_HEALTH " + json.dumps(summary, ensure_ascii=False))
sys.exit(0 if summary["ok"] else 1)
PYEOF
