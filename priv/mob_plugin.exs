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
    # TODO(stage-2): the Android `<uses-feature camera>` declaration and the
    # capture FileProvider (`<provider>` + res/xml/file_provider_paths.xml) are
    # AndroidManifest fragments the plugin manifest can't yet contribute. Either
    # add a manifest-fragment capability to the plugin system, or keep them in
    # the host template gated on mob_camera. Decision tracked in EXTRACTION.md.
  },
  ios: %{
    frameworks: ["AVFoundation", "Photos", "MobileCoreServices"],
    plist_keys: %{
      "NSCameraUsageDescription" => "The camera is used for capture and preview."
      # NSMicrophoneUsageDescription stays in core (audio); video capture relies
      # on it but core/mob_audio declares it.
    }
  }
}
