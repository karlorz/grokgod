# Plugin Skill Path Join Normalization Contract

This test suite specifies the path normalization contract for plugin skill path resolution in grok-build.
When resolving component paths (e.g. `plugin_root.join(p)` for paths specified in `plugin.json` such as `"skills": "./skills/"`),
path components representing current directory (`Component::CurDir` or `.`) must be filtered out so that paths collapse
consistently without literal `./` artifacts, while preserving parent directory references (`..`) for downstream containment checks.
