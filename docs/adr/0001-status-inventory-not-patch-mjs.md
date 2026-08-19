# 0001: Status persist inventory, not patch.mjs

grokgod tracks persist with `docs/patch-inventory.md` plus stamp-only `grok status` lines (`0001 applied|missing`, `overlay-pin wrapper|missing`), not a ClawGod `patch.mjs` regex engine. One source patch (0001) plus wrapper overlay pin. `--orca-resume-tag` removed 2026-08-19 (hit the request; durable resume is Orca-side). Status does not inspect the Mach-O or require a host overlay file.
