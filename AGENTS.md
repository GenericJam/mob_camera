# AGENTS.md — orientation for AI agents working on mob_camera

You're in **mob_camera**, a Mob plugin for on-device camera capture, live preview, and per-frame streaming. It's a Wave-2 extraction from mob core: one public Elixir surface (`MobCamera`), one NIF module (`:mob_camera_nif`) with per-platform implementations, and a Kotlin bridge on Android. Callers do `MobCamera.capture_photo/2`, `MobCamera.capture_video/2`, `MobCamera.start_preview/2`, or `MobCamera.start_frame_stream/2`; results come back as `handle_info({:camera, kind, %{…}}, socket)` messages.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — mob's three-repo topology, plugin manifest schema, `Mob.Sigil`, and the cross-cutting pre-empt-failure rules. This file is mob_camera-specific.

> **Keep this file current.** When you change capture behaviour, wire up an Android use case that today only tracks state, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_camera is, in one paragraph

A cross-platform plugin whose only Elixir surface is the `MobCamera` module. iOS uses `UIImagePickerController` for photo/video capture and a shared `AVCaptureSession` (with vImage for resize + BGRA→RGB f32) for preview + frame streaming — all in `priv/native/ios/mob_camera_nif.m`. Android uses the `TakePicture` / `CaptureVideo` activity contracts through a headless `CameraResultFragment` in `MobCameraBridge.kt`; the CameraX gradle deps are declared for the eventual `Preview` + `ImageAnalysis` binding, but the Android preview and frame-stream sides today only track state and never bind a use case, so no frame is delivered and the preview view stays blank. Capture works on both platforms; live preview and live frames are iOS-only for now. The plugin registers the `:camera` permission capability with the platform permission registry; hosts request it via `Mob.Permissions.request(socket, :camera)` before calling any capture API.

## What mob_camera is NOT

* **Not [mob_photos](https://hexdocs.pm/mob_photos).** That's the system photo/video *picker* — out-of-process, needs no camera permission, returns something the user already captured. mob_camera drives the camera itself.
* **Not [mob_scanner](https://hexdocs.pm/mob_scanner).** QR/barcode scanning. Scanner owns its own preview surface and activates mob_camera under the hood for the `:camera` permission; if you want to read a code from the camera, use mob_scanner, not this plugin.
* **Not [mob_video](https://hexdocs.pm/mob_video).** On-device clip / probe / thumbnail / extract-audio over AVFoundation + MediaCodec (no ffmpeg). Operates on a file after capture. mob_camera hands you the file; mob_video takes it from there.
* **Not [mob_screencast](https://hexdocs.pm/mob_screencast).** Captures the *device's own screen* as an H.264 stream. Nothing to do with the camera hardware.

## Anatomy of the plugin

| Path | Purpose |
|---|---|
| `lib/mob_camera.ex` | Public API. `capture_photo/2`, `capture_video/2`, `start_preview/2` / `stop_preview/1`, `start_frame_stream/2` / `stop_frame_stream/1`, plus `frame_stream_opts/1` (pure, exposed for tests). Every function is a thin wrapper that JSON-encodes options and forwards to `:mob_camera_nif`. |
| `lib/mob_camera/demo_screen.ex` | `MobCamera.DemoScreen` — the manifest's `:screens` entry. Requests `:camera`, captures a photo, shows the temp path. Delete it in a real app. |
| `src/mob_camera_nif.erl` | Erlang NIF stubs (`camera_capture_photo/1`, `camera_capture_video/1`, `camera_start_preview/1`, `camera_stop_preview/0`, `camera_start_frame_stream/1`, `camera_stop_frame_stream/0`). `on_load` tolerates a missing library so a host dev build (no native link) keeps compiling; the stubs raise `nif_not_loaded` until the on-device build links one. |
| `priv/mob_plugin.exs` | Plugin manifest. Declares the two NIF entries (iOS `:objc` + Android `:zig`), the `:camera` permission with an iOS handler symbol, iOS frameworks + `NSCameraUsageDescription`, Android CameraX gradle deps + `CAMERA` / `RECORD_AUDIO`, the Kotlin bridge class, and the FileProvider `host_requirements` warning. |
| `priv/native/ios/mob_camera_nif.m` | Objective-C NIF (ARC). Self-contained: capture delegate, shared `AVCaptureSession`, vImage frame path, and the `:camera` permission handler (`mob_camera_request_permission`) registered at NIF load. |
| `priv/native/jni/mob_camera_nif.zig` | Android JNI NIF. Caches the `MobCameraBridge` jclass + method IDs, exports the 6 NIFs, wires the `nativeDeliverCamera*` thunks. |
| `priv/native/android/MobCameraBridge.kt` | Kotlin bridge, `io.mob.camera.MobCameraBridge`. Implements `MobPermissionProvider` (`:camera` → `Manifest.permission.CAMERA`) and `MobActivityAware`; captures via a headless `CameraResultFragment` so no MainActivity changes are needed. |
| `test/mob_camera_test.exs` | Manifest + API tests (see Testing). |
| `EXTRACTION.md` | The Wave-2 extraction record — why the preview *view* stayed in core, what net-new plugin-system capabilities the full move needs. Read it before you try to move `Mob.UI.camera_preview` here. |

There is no `decisions/` directory yet — the entanglement calls (microphone stays in core; scanner/CameraX coupling deferred; FileProvider stays a host_requirement) are recorded in EXTRACTION.md.

## Cross-repo work

**mob (framework):** the preview *view* node — `Mob.UI.camera_preview/1` and its iOS/Android renderers — still lives in mob core. This plugin owns the *session* (`start_preview/2` opens an `AVCaptureSession`), core owns the view that renders it. The view reads the session this plugin's NIF exports via a weak extern (`g_preview_session`) on iOS. That split is documented in the manifest's `DESCOPE` comment and in EXTRACTION.md. Do not delete `Mob.UI.camera_preview` from core; do not move it here until the plugin native-view-bound-to-state capability lands.

**mob_dev:** the manifest tests in `test/mob_camera_test.exs` run through `MobDev.Plugin.{Manifest, Validator}` — the real pre-publish validator. mob_dev is a test-only dep and never ships.

**mob_new templates:** hosts scaffolded by `mob_new` include the FileProvider (`res/xml/file_provider_paths.xml` + the `<provider>` in AndroidManifest) that Android capture needs. Hand-rolled hosts must add it themselves or capture returns `:cancelled`. That's why the manifest has a `host_requirements` warning printed on every `mix mob.deploy --native`.

**mob_scanner (Wave 3, in progress):** shares the CameraX gradle deps. Gradle de-dups, so both can declare `androidx.camera:*:1.4.2` until scanner is extracted and points at this plugin.

## Testing

Elixir suite:

```bash
mix deps.get
mix test
```

The suite is manifest + pure-Elixir contract tests: it round-trips `Manifest.validate/1`, runs the full `Validator.validate_plugin/2` (paths, NIF modules, permissions), asserts the cross-platform NIF pattern (one module, two platforms, `:objc` + `:zig`), and asserts `:camera` is owned here while `:microphone` is not.

Native changes (`.m` / `.zig` / `.kt`) are NOT exercised by `mix test`. They need `mix mob.deploy --native` of a host app plus a physical-device check before committing — iOS simulator will show a preview but obscures capture path handling; Android emulator masks the OEM camera-service quirks (Moto G is the reference device).

## The pre-empt-failure rules that matter here

1. **`path` in `{:camera, :photo|:video, %{path: path}}` is a temp file.** Copy it elsewhere before the next capture — the next capture may reuse or reap it.
2. **Frame-stream receiver is the calling process.** `start_frame_stream/2` sends `{:camera, :frame, _}` to whoever called it. Call it from a `Mob.Screen` mount/handle_info, not from a helper GenServer that will exit while the stream is live.
3. **Android live preview + frame stream are stubs today.** `camera_start_preview` and `camera_start_frame_stream` in `MobCameraBridge.kt` set fields and bump a revision counter; nothing binds a CameraX `Preview` / `ImageAnalysis` use case, so `deliverFrame` is never called. Both calls return successfully — silent no-op, not an error. If you're touching the Android side, do not write docs that imply feature parity with iOS; check the Limits section in the README and reconcile.
4. **`:microphone` stays in core.** Video capture needs `RECORD_AUDIO` / `NSMicrophoneUsageDescription`, and the manifest declares them here so hosts get them without a second plugin, but the `:microphone` permission *capability* is registered by mob_audio / core. Do not add a `:microphone` entry to `permissions:` here — it would collide.
5. **The preview view is in core, the preview session is here.** `start_preview/2` opens the session; `Mob.UI.camera_preview/1` from core displays it, via the `extern g_preview_session` bridging decl on iOS. Rename or restatic-ify that global and the view goes blank with no error.
6. **CameraX is pinned to 1.4.2 for a reason.** 1.6.x needs `compileSdk 36` + AGP 8.9.1+ (device-build-verified failure against the current toolchain's `compileSdk 34` / AGP 8.2.0); 1.3.4 predates the 16 KB page-aligned `libimage_processing_util_jni.so` fix. Do not bump without a device build across both floors.
7. **Frame size is capped at ~4 MP.** Mismatched aspect ratios are center-cropped on the long axis before scaling. That cap keeps the BEAM mailbox bounded; do not raise it without also raising the drop policy.

## Pre-commit + release

Same pre-commit gate as the rest of mob:

```bash
mix test
mix format
mix credo --strict     # includes ExSlop + jump_credo_checks
```

The pre-push hook (activated once via `mix setup`, which does `git config core.hooksPath .githooks`) runs format / credo / compile on every push and the full suite when `mix.exs` changes.

Releases: bumping `@version` in `mix.exs` on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish, each step idempotent). See [`~/code/mob/RELEASE.md`](../mob/RELEASE.md) for the trigger model. Do not bump versions without explicit permission.
