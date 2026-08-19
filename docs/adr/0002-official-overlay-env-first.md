# 0002: Official Overlay Env First

Official Grok Build 1.0.5 natively supports `GROK_CONFIG_PATH=<toml> grok` for both interactive TUI sessions and headless `-p` executions, loading the specified TOML as an override layer above `~/.grok/config.toml`.

`grokgod run --pin` / `--overlay` is a headless `-p` helper and guard enforcer (rejecting forbidden full-config keys such as `api_key`, `[auth]`, `[mcp_servers]`, `[plugins]`, and `[subagents]`). We do not ship the host-specific Weekly Orca overlay as the product; instead we provide `examples/grok-overlay.toml`. The installer may offer to copy this template to `~/.grokgod/pin/grok-overlay.toml` if missing when run interactively (TTY) or when passed `--yes`.
