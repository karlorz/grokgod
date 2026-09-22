# DeepSeek Harness presets (names harvested, not a 1:1 port)

The preset names were harvested from DeepSeek Harness, not ported 1:1. Only
**Standard** and **Minimal** exist here.

| Preset | This host |
| --- | --- |
| Standard | Daily agent `grok-build-byok` |
| Minimal | `grokgod eval --agent minimal` |

`--agent minimal` is the DeepSeek preset name. Grok CLI `--minimal` is only
the TUI screen mode and is unrelated.

## Health probe

`grokgod eval-health [MODEL]` (default `deepseek-v4-flash`) runs two headless
Minimal probes — text (`PONG`) and native vision (transcribe
`assets/vision-probe.jpg`) — then prints one `EVAL_HEALTH` JSON line and exits
0/1. Auth is env-first: use `CLIAPI_API_KEY`/`NEW_API_KEY`, else read the
model's inline `api_key` at runtime from the daily `~/.grok/config.toml`.
Never copy the key into `eval-home` and never print it. On Orca desktop
v1.4.206-1, an automation's model comes from its automation model field
(`-m`), not from editing a model name inside the prompt.

The probe writes `~/.grokgod/eval-home/health/vision.json` (and a UTC
timestamped sibling). That file keeps `stopReason` and the full assistant
text. `sk-` tokens and env key values are replaced with `[REDACTED]`.
The file stays out of git.
