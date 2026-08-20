# Changelog

All notable changes to **mob_camera** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.4] - 2026-08-19

### Fixed
- **Guaranteed native crash (SIGSEGV) on the first delivered camera frame on
  Android.** The `nativeDeliverCameraFrame` zig export declared a raw
  `[*]const u8, usize` pointer+length pair for what Kotlin's `external fun`
  declares as a single `ByteArray` — JNI binds natives by name only, so every
  argument after `bytes` shifted one slot: `nbytes` received `width`, and
  `format` received the `timestampMs` value, later dereferenced as a C string
  via `enif_make_atom`. Fixed to match the Kotlin signature slot-for-slot (a
  `jbyteArray` copied via `GetByteArrayRegion`, a `jstring` read via
  `GetStringUTFChars`), mirroring the sibling `nativeDeliverCameraFile`
  export. Was latent — nothing on Android drives `deliverFrame` yet — but
  guaranteed to crash the instant anything does. Source-contract regression
  test added; device-verified on a physical Moto G Power (2021). (MOB-41, #2)

## [0.1.3] - 2026-06-24

### Fixed
- **Taking a photo no longer wedges the app on Android.** `launchCapture`
  arrives on a BEAM scheduler thread, but `ActivityResultRegistry.register()`
  and `ActivityResultLauncher.launch()` must run on the Android main thread
  (off-thread they throw `IllegalStateException` / wedge the UI toolkit, so the
  host froze on "Take Photo"). Both now run inside `activity.runOnUiThread`.
  Source-contract regression test; device-verified on a Moto G power 5G. (#1)

### Security
- Bumped `plug` 1.19.2 → 1.20.1 (dev/test-only transitive via `mob_dev`),
  clearing EEF-CVE-2026-54892 (quadratic-time nested-param decoding DoS).
  Lockfile-only; does not ship in the package.

---

## [0.1.2] - 2026-06-16

### Changed
- Signed release: the published package now carries a verified Ed25519
  signature (shared mob first-party key, regenerated in CI on every
  release). Generated apps trust it via `config :mob, :trusted_plugins`,
  so it clears the plugin signature gate without `acknowledge_unsafe_plugins`.

## [0.1.1] - 2026-06-15

### Added
- Bundled `MobCamera.DemoScreen` — a ready-to-run capture sample declared in the manifest's `:screens`, so a generated app can kick the tires on activation. It's pure-Elixir and hot-pushable; the plugin is now tier 3 (NIF + screens). Delete the screen + its `:screens` entry in a real app.

## [0.1.0] - 2026-06-12

Initial release. Native camera capture, live preview, and frame streaming for Mob apps.

- `MobCamera.capture_photo/1`, `start_preview/2` / `stop_preview/1`, and `start_frame_stream/2` for on-device frame delivery.
- Extracted from mob core in the 0.7.0 plugin-extraction wave.
- Requires `mob ~> 0.7`.
