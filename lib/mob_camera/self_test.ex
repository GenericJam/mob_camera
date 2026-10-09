defmodule MobCamera.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One native call, no camera session, no UI: `camera_stop_preview/0`, which
  is a no-op while nothing previews.

    * iOS: the Objective-C NIF queues the teardown on the plugin's serial
      camera queue (dropping a session that does not exist) and answers
      `:ok`. The answer proves `mob_camera_nif.m` is linked and its NIF table
      registered; no `AVCaptureDevice` is touched, so the simulator, which
      has no camera, passes the same way a phone does.
    * Android: the zig NIF calls the static `MobCameraBridge.camera_stop_preview`
      through JNI, which clears the requested preview facing, and answers
      `:ok`. That proves the zig NIF is linked and the Kotlin bridge
      registered (`nativeRegister` cached the class and method IDs). An
      emulator without a camera passes: CameraX is not involved.
      `{:error, :bridge_not_registered}` means the host's plugin bootstrap
      never called `MobCameraBridge.register()` or a method-ID lookup
      failed; `:error` means the NIF could not attach to the JVM. Both fail.

  There is no `{:skip, :needs_hardware}` branch: neither platform exposes a
  read-only "is there a camera" query, and the only call that would find
  out (`camera_snap/1`, which reports `:no_camera`) opens a capture session,
  which a self-test must not do. Capturing a frame is the feature, not the
  proof.

  The host stub's `nif_not_loaded` is a failure. Run it while the host is
  not previewing: `camera_stop_preview/0` would end a running preview.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(ctx), do: run(ctx, :mob_camera_nif)

  @doc false
  @spec run(Mob.Plugin.SelfTest.ctx(), module()) :: Mob.Plugin.SelfTest.result()
  def run(%{platform: platform}, nif) do
    case nif.camera_stop_preview() do
      :ok ->
        :pass

      {:error, :bridge_not_registered} ->
        {:fail,
         "camera_stop_preview/0 on #{platform} returned {:error, :bridge_not_registered}: " <>
           "the Kotlin MobCameraBridge was never registered (nativeRegister did not run " <>
           "or a method-ID lookup failed), expected :ok"}

      other ->
        {:fail, "camera_stop_preview/0 on #{platform} returned #{inspect(other)}, expected :ok"}
    end
  rescue
    e in [ErlangError, UndefinedFunctionError] ->
      {:fail,
       "#{inspect(nif)} is not linked into this build: camera_stop_preview/0 raised " <>
         Exception.message(e)}
  end
end
