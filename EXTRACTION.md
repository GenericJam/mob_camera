# mob_camera extraction — progress + checklist

Extracting all camera functionality out of mob core into this plugin (Wave 2),
following the `mob_location` template. Staged across turns.

## Status

- [x] **Stage 1a — package + Elixir + manifest** (this commit): `mix.exs`,
  `lib/mob_camera.ex` (full `MobCamera` API: capture_photo/video, preview/1,
  start/stop_preview, start/stop_frame_stream, frame_stream_opts — parity with
  the old `Mob.Camera` + `Mob.UI.camera_preview`), `src/mob_camera_nif.erl`
  (6 NIF stubs), `priv/mob_plugin.exs` (manifest spec).
- [ ] **Stage 1b — native sources moved** (next): extract the native code from
  core into this plugin, self-contained (see checklist below).
- [ ] **Stage 2 — strip core + mob_new templates.**
- [ ] **Stage 3 — device-verify** iPhone + Moto G (capture, preview, frame
  stream, `:camera` permission via registry), parity before/after.
- [ ] **Stage 4 — contract tests, docs, CHANGELOG, mob_new wizard opt-in.**

## Native extraction checklist (Stage 1b) — source: core survey

### iOS — `priv/native/ios/mob_camera_nif.m` (extract, make self-contained)
From `mob/ios/mob_nif.m`:
- Permission branch (lines 2357–2365) — the **camera** half only (`AVMediaTypeVideo`).
- `MobCameraDelegate` + capture (2424–2526): UIImagePickerController photo/video.
- Shared session + preview (2528–2643): `g_preview_session`, `mob_camera_ensure_session`, start/stop_preview.
- Frame stream (2645–2948): `MobFrameDelegate`, vImage resize + BGRA→RGB f32, start/stop_frame_stream.
- NIF table entries (6716–6721).

**Self-contained adaptations (core helpers are private statics — not linkable):**
- `mob_send2`/`mob_send3` → own `enif_send` helpers (cf. `mob_location_nif.m` `send_permission`).
- `mob_root_vc()` → `UIApplication.sharedApplication.keyWindow.rootViewController` (or the connected-scene equivalent) directly.
- `extern void mob_register_permission_handler(const char *, void (*)(ErlNifPid));` — register `"camera"` in the `load` callback (core exports it; same static binary).
- `ERL_NIF_INIT(mob_camera_nif, …, load, …)`.

### iOS — `priv/native/ios/MobCameraPreviewView.swift`
From `mob/ios/MobRootView.swift` (899–975): `CameraPreviewUIView` + `MobCameraPreviewView` (UIViewRepresentable) + the `MobCameraSessionChanged` observer. Register it under the native view key `"MobCamera_PreviewView"` (the `ui_components` entry). It references the `.m`'s `g_preview_session` global — declare `extern AVCaptureSession *g_preview_session;` (the `.m` must export it, not `static`).

### Android — `priv/native/jni/mob_camera_nif.zig`
From `mob/android/jni/mob_nif.zig`: bridge method IDs (248–253), `mob_deliver_camera_frame` (2328–2365), 6 NIF impls (2607–2691), method caching (3548–3553), NIF table (3683–3688). Self-register the Kotlin bridge class via `MobCameraBridge` (cf. `MobLocationBridge`).

### Android — `priv/native/android/MobCameraBridge.kt`
The CameraX impl (TakePicture/CaptureVideo activity contracts, ImageAnalysis + ARGB→BGRA repack, FileProvider URI). Currently lives in the **mob_new host templates / host MainActivity**, not core — move it here. Implements `MobPermissionProvider` (maps `:camera` → `Manifest.permission.CAMERA`) and registers via `MobPluginBootstrap`.

## Entanglement decisions

1. **Microphone stays in core.** The iOS permission branch handles camera + mic
   together; mic is needed by `Mob.Audio` (recording, stays in core). Split:
   core keeps the `:microphone` → `AVMediaTypeAudio` branch; this plugin owns
   `:camera` only (and declares the `RECORD_AUDIO`/`NSMicrophone…` *manifest*
   entries for video — harmless set-union with core/mob_audio).
2. **Scanner/CameraX coupling deferred.** `mob_scanner` (core, Wave 3) shares the
   CameraX gradle deps. This plugin declares its own CameraX deps; gradle dedups,
   so the in-core scanner keeps working. Extract scanner later, pointing at
   `mob_camera`.
3. **FileProvider + `<uses-feature>` (Android).** These are AndroidManifest
   fragments the plugin manifest can't yet contribute (only `<uses-permission>`
   + gradle deps). Stage-2 decision: add a manifest-fragment capability to the
   plugin system, or keep them in the host template gated on `mob_camera`.

## Precedent

Breaking, **no compatibility shim** — matches the `mob_location` extraction
(core provided no location shim). Apps using `Mob.Camera.*` add
`{:mob_camera, "~> 0.1"}` and call `MobCamera.*`.
