# Disable compiled-in deep-research via config, not the workflows master switch

Official grok-build has `[workflows] enabled = false`, which kills the
`workflow` tool, named scripts, `/deep-research`, and the host `/goal`
driver. The compiled-in workflow also occupies the `/deep-research` slash
name, so plugin `deep-research:deep-research` cannot advertise the bare
command.

0004 adds `[workflows.builtins] deep-research` (compiled default **true**).
Explicit `false` drops the builtin from the registry, slash catalog, and
name-resolve path. `/settings` → Agent → Built-in deep-research workflow
persists the same key. grokgod install merges `false` when the key is
absent.

Rejected: `[workflows] enabled = false`; renaming the plugin; upstream PR
(xai-org issues-off).
