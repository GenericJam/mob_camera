# Changelog

All notable changes to **mob_camera** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.8] - 2026-08-25

### Fixed
- **Android 15+ 16 KB page-alignment warning.** `libimage_processing_util_jni.so`
  (androidx.camera) was flagged as not 16 KB page-aligned on Android 15+
  devices/emulators. Bumped `androidx.camera:camera-{camera2,lifecycle,view}`
  1.3.4 → 1.4.2 (the earliest CameraX release with 16 KB-aligned native
  libs). Deliberately not the current-stable 1.6.x line — 1.6.1 requires
  compileSdk 36 + AGP 8.9.1+, which a real device build against this
  toolchain's compileSdk 34/AGP 8.2.0 confirmed fails outright. Device-
  verified on a physical Moto G: build, boot, and `MobCamera` module load
  all clean. (MOB-95)

## [0.1.7] - 2026-08-21

### Docs
- **README and moduledoc presented Android live preview and frame
  streaming as working, when neither is implemented.** The README's
  opening line claimed "CameraX `ImageAnalysis`" for Android, and the
  usage examples for `start_frame_stream/2` / `start_preview/2` were shown
  with no platform caveat. In reality `camera_start_preview`/
  `camera_start_frame_stream` in `MobCameraBridge.kt` only set state fields
  and bump a revision counter — nothing binds a CameraX `Preview`/
  `ImageAnalysis` use case to the session, so `deliverFrame` is never
  called and no frame or preview ever reaches Android. Both calls return
  successfully with no error, so a caller following the docs would see a
  `FunctionClauseError`-free but silently no-op integration. Added an
  explicit "Platform support" matrix to the README and `MobCamera`
  moduledoc, caveated both usage examples, and expanded the Limits section
  to name the exact gap (state tracking exists, the CameraX binding
  doesn't) rather than only describing the preview view's core/plugin
  split. Capture (`capture_photo/2`, `capture_video/2`) is unaffected —
  fully implemented on both platforms. (MOB-66)

## [0.1.6] - 2026-08-20

### Fixed
- **iOS `stop_preview` left `g_camera_input`/`g_camera_facing`/`g_frame_output`/
  `g_frame_delegate` stale, and mutated the shared session globals on the main
  queue instead of the serial queue everything else uses — a silent black
  preview on the next `start_preview`/`start_frame_stream`.**
  `nif_camera_stop_preview` only nilled `g_preview_session`, on
  `dispatch_get_main_queue()`, while `mob_camera_ensure_session` (and
  `start_frame_stream`) mutate the other four globals on the serial
  `mob_camera_queue()` — a cross-queue race. Worse, leaving `g_camera_input`
  non-nil meant the next `ensure_session` call with the same facing hit its
  fast path (`g_camera_input && [g_camera_facing isEqualToString:facing]`)
  and returned success without ever adding an input to the freshly-created
  session. Fixed by moving the teardown onto `mob_camera_queue()` and nilling
  all five session-identity globals together. Added a source-level
  regression test asserting both properties. Device-verified on a physical
  iPhone SE (3rd gen): starting preview, stopping, and starting again now
  shows a live feed both times (previously black the second time).
  (MOB-67)

## [0.1.5] - 2026-08-20

### Fixed
- **Android capture result map was missing `:width`/`:height` (photo) and
  `:duration` (video), contradicting the documented shapes.**
  `nativeDeliverCameraFile` only ever built `%{path: p}`, so the
  `{:camera, :photo, %{path:, width:, height:}}` / `{:camera, :video,
  %{path:, duration:}}` clauses shown in the README and moduledoc could never
  match on Android — any `handle_info` written against the docs raised
  `FunctionClauseError` and crashed the screen GenServer. iOS already
  included these fields, making this a silent platform asymmetry. Fixed by
  having `MobCameraBridge.kt` decode the captured file (`BitmapFactory`
  bounds for photo dimensions, `MediaMetadataRetriever` duration for video,
  converted from ms to seconds) and extending `nativeDeliverCameraFile`'s
  JNI signature to carry `width`/`height`/`duration_seconds` through to the
  Zig NIF, which now builds the kind-appropriate map. Device-verified on a
  physical Moto G Power (2021): photo delivered real `width: 4000, height:
  3000`; video delivered real `duration: 30.104`. (MOB-68)

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
