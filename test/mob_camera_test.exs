defmodule MobCameraTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 3 (NIF + a demo screen)", %{manifest: m} do
      # The capability NIF alone is tier 1; the bundled demo screen (a tier-3
      # :screens section) lifts it to 3. tier/1 reports the highest section.
      assert Manifest.tier(m) == 3
    end

    test "passes the full pre-publish validator (paths, NIF modules, permissions)",
         %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_camera_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_camera_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "owns :camera but NOT :microphone (mic stays in core for audio)", %{manifest: m} do
      assert [%{capability: :camera}] = m.permissions
      refute Enum.any?(m.permissions, &(&1.capability == :microphone))
    end

    test "declares the FileProvider host requirement for non-template hosts",
         %{manifest: m} do
      assert [req] = m.host_requirements
      assert req =~ "FileProvider"
    end

    test "every native source dir + Kotlin bridge the manifest references exists",
         %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))
    end
  end

  describe "android capture threading (regression)" do
    # The camera NIF callback arrives on a BEAM scheduler thread, but
    # ActivityResultRegistry.register() + launcher.launch() MUST run on the Android
    # main thread — off-thread they throw IllegalStateException / wedge the UI toolkit,
    # and the host app appears to hang on "Take Photo" (seen in GenericJam/sloppy_joe).
    # launchCapture must hop to the UI thread for BOTH the registration and the launch.
    # Source-level because JNI threading isn't exercisable from mix test (see CLAUDE.md).
    setup do
      {:ok, m} = Manifest.load(@plugin_dir)
      %{src: File.read!(Path.join(@plugin_dir, m.android.bridge_kt))}
    end

    test "registers + launches the ActivityResult inside runOnUiThread", %{src: src} do
      assert src =~ "runOnUiThread", "camera capture must hop to the Android main thread"

      # Everything after the hop: both the register and the launch must live inside it.
      [_before, after_hop] = String.split(src, "runOnUiThread", parts: 2)

      assert after_hop =~ "activityResultRegistry.register",
             "register() must run inside runOnUiThread"

      assert after_hop =~ "launcher.launch",
             "launch() must run inside runOnUiThread"
    end
  end

  describe "iOS stop_preview teardown (MOB-67 regression)" do
    # stop_preview used to nil only g_preview_session, and to do it on the main
    # queue while mob_camera_ensure_session mutates g_camera_input/g_camera_facing/
    # g_frame_output/g_frame_delegate on the serial mob_camera_queue(). That left
    # a stale, non-nil g_camera_input pointing at the discarded session's input:
    # the next ensure_session's fast path (`g_camera_input && facing matches`)
    # returned YES without ever adding an input to the NEW session — a silent
    # black preview. Source-level because AVCaptureSession state isn't
    # exercisable from `mix test` (see CLAUDE.md).
    setup do
      %{src: File.read!(Path.join(@plugin_dir, "priv/native/ios/mob_camera_nif.m"))}
    end

    defp stop_preview_body(src) do
      [_, body] =
        Regex.run(
          ~r/nif_camera_stop_preview\(ErlNifEnv \*env, int argc, const ERL_NIF_TERM argv\[\]\) \{(.*?)\n\}/s,
          src
        )

      body
    end

    test "teardown runs on mob_camera_queue(), not the main queue", %{src: src} do
      body = stop_preview_body(src)

      assert body =~ "dispatch_async(mob_camera_queue()",
             "stop_preview must serialize its teardown on the same queue " <>
               "mob_camera_ensure_session mutates the session globals on"

      refute String.trim(body) =~ ~r/^dispatch_async\(dispatch_get_main_queue\(\)/,
             "teardown must not mutate the session globals directly on the main queue"
    end

    test "nils every session-identity global, not just g_preview_session", %{src: src} do
      body = stop_preview_body(src)

      for global <-
            ~w(g_preview_session g_camera_input g_camera_facing g_frame_output g_frame_delegate) do
        assert body =~ "#{global} = nil;",
               "#{global} must be nilled in stop_preview, or the next ensure_session's " <>
                 "fast path matches stale state and silently skips adding an input " <>
                 "to the new session"
      end
    end
  end

  describe "NIF stub agreement" do
    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_camera_nif)
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_camera_nif.module_info(:exports)

      for fa <- [
            camera_capture_photo: 1,
            camera_capture_video: 1,
            camera_start_preview: 1,
            camera_stop_preview: 0,
            camera_start_frame_stream: 1,
            camera_stop_frame_stream: 0
          ] do
        assert fa in exports, "#{inspect(fa)} missing from mob_camera_nif exports"
      end
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_camera_nif.camera_stop_preview()
      end
    end
  end

  describe "frame_stream_opts/1" do
    test "defaults are YOLO-friendly 640x640 rgb_f32 back camera, unthrottled" do
      assert MobCamera.frame_stream_opts([]) == %{
               "width" => 640,
               "height" => 640,
               "format" => "rgb_f32",
               "facing" => "back",
               "throttle_ms" => 0
             }
    end

    test "every option overrides its default and serialises to strings/ints" do
      opts = [width: 320, height: 240, format: :bgra_u8, facing: :front, throttle_ms: 100]

      assert MobCamera.frame_stream_opts(opts) == %{
               "width" => 320,
               "height" => 240,
               "format" => "bgra_u8",
               "facing" => "front",
               "throttle_ms" => 100
             }
    end

    test "the opts map round-trips through :json (what the NIF actually receives)" do
      decoded =
        MobCamera.frame_stream_opts([])
        |> :json.encode()
        |> IO.iodata_to_binary()
        |> :json.decode()

      assert decoded["format"] == "rgb_f32"
      assert decoded["width"] == 640
    end
  end

  describe "public API surface (extraction parity with old Mob.Camera)" do
    test "exports the full extracted surface" do
      exports = MobCamera.__info__(:functions)

      for fa <- [
            capture_photo: 2,
            capture_video: 2,
            start_preview: 2,
            stop_preview: 1,
            start_frame_stream: 2,
            stop_frame_stream: 1,
            frame_stream_opts: 1
          ] do
        assert fa in exports, "#{inspect(fa)} missing from MobCamera"
      end
    end
  end

  # ── nativeDeliverCameraFrame JNI-contract helpers (module scope) ──────────
  # Kotlin: `Long`/`ByteArray`/`Int`/`String` ⇄ zig JNI: `JLong`/`JByteArray`/`JInt`/`JString`.
  @kt_to_zig %{
    "Long" => "JLong",
    "ByteArray" => "JByteArray",
    "Int" => "JInt",
    "String" => "JString",
    "Double" => "JDouble"
  }

  # each param is `name: Type,` — capture the Type (allow a `jni.`/`*` prefix in zig).
  defp param_types(block) do
    ~r/\w+\s*:\s*\*?(?:jni\.)?([A-Za-z]\w*)/
    |> Regex.scan(block)
    |> Enum.map(fn [_, t] -> t end)
  end

  defp zig_frame_params(zig) do
    [_, block] =
      Regex.run(
        ~r/export fn Java_io_mob_camera_MobCameraBridge_nativeDeliverCameraFrame\((.*?)\)\s*callconv/s,
        zig
      )

    block
  end

  describe "nativeDeliverCameraFrame JNI contract (MOB-41 regression)" do
    # JNI binds natives by NAME only, so the zig export's parameter list must
    # match the Kotlin `external fun` slot-for-slot (after the JNIEnv*/jclass
    # prefix). MOB-41: the byte[] param was declared as a `[*]const u8, usize`
    # pointer+length PAIR, shifting every later arg by one slot — the format
    # jstring landed in the timestamp slot and was deref'd as a C string →
    # guaranteed SIGSEGV on the first delivered frame. Source-level because the
    # JNI boundary isn't exercisable from `mix test` (see the sibling regressions
    # above and CLAUDE.md).
    setup do
      {:ok, m} = Manifest.load(@plugin_dir)

      %{
        kt: File.read!(Path.join(@plugin_dir, m.android.bridge_kt)),
        zig: File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_camera_nif.zig"))
      }
    end

    test "the zig export matches the Kotlin external fun slot-for-slot", %{kt: kt, zig: zig} do
      [_, kt_block] = Regex.run(~r/external fun nativeDeliverCameraFrame\((.*?)\)/s, kt)
      kt_types = param_types(kt_block)

      # Drop the JNIEnv* + jclass the JVM prepends; the rest must line up 1:1.
      zig_types = zig |> zig_frame_params() |> param_types() |> Enum.drop(2)

      assert length(zig_types) == length(kt_types),
             "arity mismatch: Kotlin declares #{length(kt_types)} params, zig export has " <>
               "#{length(zig_types)} (a JByteArray must be ONE slot, not a ptr+len pair)"

      assert Enum.map(kt_types, &Map.fetch!(@kt_to_zig, &1)) == zig_types
    end

    test "the byte[] param is a single JByteArray, never a raw pointer+length", %{zig: zig} do
      block = zig_frame_params(zig)

      assert block =~ "jni.JByteArray"

      refute block =~ ~r/\[\*\](?:const )?u8/,
             "byte[] must be read via GetByteArrayRegion, not a `[*]const u8` slot"
    end
  end

  defp zig_file_params(zig) do
    [_, block] =
      Regex.run(
        ~r/export fn Java_io_mob_camera_MobCameraBridge_nativeDeliverCameraFile\((.*?)\)\s*callconv/s,
        zig
      )

    block
  end

  describe "nativeDeliverCameraFile JNI contract (MOB-68 regression)" do
    # Same failure class as MOB-41 above, one level over: MOB-68 extended this
    # export with width/height/durationSeconds to fix the missing result-map
    # fields, and JNI's name-only binding means any future edit to either side
    # (Kotlin `external fun` or the zig `export fn`) without the other is a
    # silent slot-shift, not a compile error.
    setup do
      {:ok, m} = Manifest.load(@plugin_dir)

      %{
        kt: File.read!(Path.join(@plugin_dir, m.android.bridge_kt)),
        zig: File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_camera_nif.zig"))
      }
    end

    test "the zig export matches the Kotlin external fun slot-for-slot", %{kt: kt, zig: zig} do
      [_, kt_block] = Regex.run(~r/external fun nativeDeliverCameraFile\((.*?)\)/s, kt)
      kt_types = param_types(kt_block)

      zig_types = zig |> zig_file_params() |> param_types() |> Enum.drop(2)

      assert length(zig_types) == length(kt_types),
             "arity mismatch: Kotlin declares #{length(kt_types)} params, zig export has " <>
               "#{length(zig_types)} params"

      assert Enum.map(kt_types, &Map.fetch!(@kt_to_zig, &1)) == zig_types
    end
  end
end
