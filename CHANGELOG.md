# Changelog

All notable changes to **mob_camera** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.1] - 2026-06-15

### Added
- Bundled `MobCamera.DemoScreen` — a ready-to-run capture sample declared in the manifest's `:screens`, so a generated app can kick the tires on activation. It's pure-Elixir and hot-pushable; the plugin is now tier 3 (NIF + screens). Delete the screen + its `:screens` entry in a real app.

## [0.1.0] - 2026-06-12

Initial release. Native camera capture, live preview, and frame streaming for Mob apps.

- `MobCamera.capture_photo/1`, `start_preview/2` / `stop_preview/1`, and `start_frame_stream/2` for on-device frame delivery.
- Extracted from mob core in the 0.7.0 plugin-extraction wave.
- Requires `mob ~> 0.7`.
