%{
  name: :mob_camera,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description:
    "Native camera capture, live preview, and frame streaming — extracted from mob core in Wave 2",
  nifs: [
    # iOS: Objective-C NIF — UIImagePickerController capture, a shared
    # AVCaptureSession for preview + frame streaming (vImage resize/convert),
    # and the :camera permission flow. lang: :objc -> compiled as ObjC
    # (-fobjc-arc); platform: :ios so it isn't pulled into the Android build.
    %{module: :mob_camera_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to CameraX via the Kotlin MobCameraBridge.
    %{module: :mob_camera_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  # DESCOPE: the live-preview VIEW stays in mob core for now (its renderer node
  # reads the session this plugin's NIF owns, via a weak extern). So this plugin
  # does NOT ship a preview component yet — apps use `Mob.UI.camera_preview`
  # (core) for the view + `MobCamera.start_preview/2` (this plugin) to activate
  # the session. The preview-as-plugin-component move waits on the plugin
  # native-view-bound-to-state capability (see EXTRACTION.md).
  permissions: [
    # iOS handler self-registered at NIF load (mob_camera_request_permission ->
    # AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo); Android mapping
    # via MobCameraBridge implementing MobPermissionProvider. NOTE: :microphone
    # stays in CORE (audio recording needs it); this plugin only owns :camera.
    %{capability: :camera, ios: %{handler: "mob_camera_request_permission"}}
  ],
  android: %{
    bridge_kt: "priv/native/android/MobCameraBridge.kt",
    bridge_class: "io.mob.camera.MobCameraBridge",
    permissions: [
      "android.permission.CAMERA",
      # Video recording. Microphone permission is also declared by mob_audio /
      # core; set-unioned, so declaring it here too is harmless.
      "android.permission.RECORD_AUDIO"
    ],
    # Frame streaming (ImageAnalysis). Capture (TakePicture/CaptureVideo) ships
    # with the SDK. These are also used by the in-core QR scanner today — gradle
    # de-dups, so both can declare them until mob_scanner is extracted.
    gradle_deps: [
      "androidx.camera:camera-camera2:1.3.4",
      "androidx.camera:camera-lifecycle:1.3.4",
      "androidx.camera:camera-view:1.3.4"
    ]
    # The capture FileProvider + <uses-feature camera> are AndroidManifest
    # fragments the plugin manifest can't yet contribute (Stage-2 decision,
    # tracked in EXTRACTION.md). Declared in :host_requirements below so every
    # native build reminds the host author; mob_new-generated apps already
    # carry the FileProvider in their template.
  },
  ios: %{
    frameworks: ["AVFoundation", "Photos", "MobileCoreServices"],
    plist_keys: %{
      "NSCameraUsageDescription" => "The camera is used for capture and preview."
      # NSMicrophoneUsageDescription stays in core (audio); video capture relies
      # on it but core/mob_audio declares it.
    }
  },
  # Manual host-app steps the build can't automate; printed as a warning on
  # every `mix mob.deploy --native` of the host. mob_new-generated apps already
  # satisfy this via their template AndroidManifest.
  host_requirements: [
    "Photo/video capture saves through a FileProvider: AndroidManifest.xml must " <>
      ~s(declare <provider android:name="androidx.core.content.FileProvider" ...> ) <>
      "with res/xml/file_provider_paths.xml (mob_new-generated apps include it; " <>
      "hand-rolled hosts must add it or capture returns cancelled)."
  ]
}
