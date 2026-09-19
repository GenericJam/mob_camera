# mob_camera — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md) for the system view. Together they cover the plugin anatomy, the iOS/Android split (capture on both, live preview + frame stream iOS-only for now), the preview-view-in-core / preview-session-here rule, and the cross-repo work with mob / mob_dev / mob_new.

> **Keep AGENTS.md up to date** when you change capture behaviour, wire up an Android use case that today only tracks state, or hit a new gotcha. Out-of-date guidance there causes wrong decisions downstream — fix it in the same commit, not in a follow-up.

## Pre-commit checklist

```bash
mix test
mix format
mix credo --strict       # includes ExSlop + jump_credo_checks
```

Native changes (`.m` / `.zig` / `.kt`) aren't exercised by `mix test` — they need a `mix mob.deploy --native` of a host app (e.g. `mob_plugin_demo`) and a physical-device check before committing. iOS Simulator obscures capture-path handling; Android emulator masks OEM camera-service quirks.

The pre-push hook (`.githooks/pre-push`, activated via `mix setup` → `git config core.hooksPath .githooks`) runs format / credo / compile on every push and the full suite when `mix.exs` changes (release preflight).

## Releases

`mix.exs` `@version` bump on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish). See [`~/code/mob/RELEASE.md`](../mob/RELEASE.md) for the trigger model; do NOT bump versions without explicit permission.
