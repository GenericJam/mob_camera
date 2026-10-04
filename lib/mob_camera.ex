defmodule MobCamera do
  @moduledoc """
  Native camera capture, live preview, and frame streaming — a Mob plugin
  (extracted from mob core in Wave 2).

  Requires `:camera` permission (request via `Mob.Permissions.request/2`; this
  plugin registers the `:camera` capability with the platform permission
  registry), plus `:microphone` for video. iOS additionally needs
  `NSCameraUsageDescription` (and `NSMicrophoneUsageDescription` for video) in
  `Info.plist`; Android needs `CAMERA` (and `RECORD_AUDIO` for video) — all
  merged from this plugin's manifest at build time.

  Capture results arrive as:

      handle_info({:camera, :photo, %{path: path, width: w, height: h}}, socket)
      handle_info({:camera, :video, %{path: path, duration: seconds}},   socket)
      handle_info({:camera, :cancelled},                                   socket)

  The `path` is a local temp file. Copy it elsewhere before the next capture.

  iOS: `UIImagePickerController`. Android: `TakePicture` / `CaptureVideo` activity contracts.

  ## Headless still (`snap/1`)

  `snap/1` takes a photo with no preview and no user action — for code (an
  agent, a timer, a sensor trigger) that wants to see what the camera sees.
  It returns `:ok` and messages the calling process:

      handle_info({:camera, :snapped, %{path: path, width: w, height: h, facing: :back}}, socket)
      handle_info({:camera, :snap_error, reason}, socket)

  iOS: `AVCaptureSession` + `AVCapturePhotoOutput`. Android: CameraX
  `ImageCapture` on its own lifecycle. See `snap/1` for options and reasons.

  ## Platform support

  Capture (`capture_photo/2`, `capture_video/2`) and `snap/1` are fully
  implemented on both platforms. Live preview (`start_preview/2`) and frame
  streaming (`start_frame_stream/2`) are **iOS-only** for now — see the `@doc`
  on each and the README's Limits section for why.

  ## Live frame stream

  For real-time work (object detection, AR, custom filters) `start_frame_stream/2`
  delivers per-frame pixel data as messages (**iOS only** — see Platform
  support above):

      handle_info({:camera, :frame, %{bytes: bin, width: w, height: h,
                                       format: :rgb_f32,
                                       timestamp_ms: t, dropped: n}}, socket)

  The native side handles resize + format conversion (vImage on iOS, CameraX
  ImageAnalysis + Bitmap on Android) so the BEAM never sees raw camera buffers.
  Late frames are dropped natively so the mailbox can't unbounded-grow.

  ## Live preview

  Pair `start_preview/2` with a `Mob.UI.camera_preview/1` component (in mob core)
  in your render tree to show the feed (**iOS only** — see Platform support
  above):

      use Mob.Sigil
      # in render/1:
      {Mob.UI.camera_preview(facing: :back)}
  """

  @doc """
  Open the camera to capture a photo.

  Options:
    - `quality: :high | :medium | :low` (default `:high`) — JPEG compression level
  """
  @spec capture_photo(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def capture_photo(socket, opts \\ []) do
    quality = Keyword.get(opts, :quality, :high)
    :mob_camera_nif.camera_capture_photo(quality)
    socket
  end

  @doc """
  Open the camera to record a video.

  Options:
    - `max_duration: integer` — maximum clip length in seconds (default `60`)
  """
  @spec capture_video(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def capture_video(socket, opts \\ []) do
    max_duration = Keyword.get(opts, :max_duration, 60)
    :mob_camera_nif.camera_capture_video(max_duration)
    socket
  end

  @doc """
  Start a live camera preview session. Pair with a `Mob.UI.camera_preview/1`
  component (in mob core) in your render tree to display the feed.

  **iOS only.** On Android this returns successfully and tracks the
  requested facing, but nothing binds a CameraX use case to the session yet,
  so the preview view stays blank — see the module's Platform support
  section and the README's Limits section.

  Options:
    - `facing: :back | :front` (default `:back`)
  """
  @spec start_preview(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def start_preview(socket, opts \\ []) do
    facing = Keyword.get(opts, :facing, :back) |> Atom.to_string()
    :mob_camera_nif.camera_start_preview(:json.encode(%{"facing" => facing}))
    socket
  end

  @doc "Stop the active camera preview session."
  @spec stop_preview(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_preview(socket) do
    :mob_camera_nif.camera_stop_preview()
    socket
  end

  @doc """
  Start streaming camera frames to the calling process.

  **iOS only.** On Android this returns successfully and tracks the
  requested options, but nothing binds a CameraX `ImageAnalysis` use case to
  the session yet, so no `{:camera, :frame, _}` message is ever delivered —
  see the module's Platform support section and the README's Limits section.

  Frames arrive as messages of shape:

      handle_info({:camera, :frame, %{
        bytes:        binary(),      # pixel data, format-dependent
        width:        non_neg_integer(),
        height:       non_neg_integer(),
        format:       :rgb_f32 | :bgra_u8,
        timestamp_ms: non_neg_integer(),
        dropped:      non_neg_integer()  # frames skipped since last delivery
      }}, socket)

  ## Options

    * `:width`, `:height` — target frame size in pixels. Defaults to `640` × `640`
      (YOLO-friendly). Mismatched aspect ratios are center-cropped on the long
      axis before scaling. Capped at ~4 MP to keep the BEAM mailbox bounded (a
      larger request is delivered as `2048` × `2048`).

      Pass `nil` for **both** to receive the camera's native resolution instead:
      no crop, no scale, upright portrait — the delivered `width`/`height` are the
      capture buffer's own (e.g. `1080` × `1920` on an iPhone). A native frame
      above the ~4 MP cap is downscaled with its aspect ratio kept. Passing `nil`
      for only one of the two raises `ArgumentError`.

    * `:format` — pixel format. One of:
      - `:rgb_f32` (default) — interleaved RGB floats normalised to `[0.0, 1.0]`.
        Byte size: `width * height * 3 * 4`. Ready for
        `Nx.from_binary(bin, :f32, ...) |> Nx.reshape({1, h, w, 3})`.
      - `:bgra_u8` — raw 32-bit BGRA bytes. Byte size: `width * height * 4`.

    * `:facing` — `:back` (default) or `:front`.

    * `:throttle_ms` — minimum interval between deliveries (default `0`).

  Returns the socket immediately; frames begin arriving asynchronously once the
  OS has activated the capture session. Receiver is the **calling process** —
  call from a `Mob.Screen` callback (mount, handle_info), not from elsewhere.
  """
  @spec start_frame_stream(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def start_frame_stream(socket, opts \\ []) do
    :mob_camera_nif.camera_start_frame_stream(:json.encode(frame_stream_opts(opts)))
    socket
  end

  @doc """
  Build the option map passed to `camera_start_frame_stream/1`. Pure function
  exposed so tests can pin defaults + serialisation without going through the NIF.
  """
  @spec frame_stream_opts(keyword()) :: map()
  def frame_stream_opts(opts) do
    {width, height} = frame_size(Keyword.get(opts, :width, 640), Keyword.get(opts, :height, 640))

    %{
      "width" => width,
      "height" => height,
      "format" => Keyword.get(opts, :format, :rgb_f32) |> Atom.to_string(),
      "facing" => Keyword.get(opts, :facing, :back) |> Atom.to_string(),
      "throttle_ms" => Keyword.get(opts, :throttle_ms, 0)
    }
  end

  # Native resolution is sent as JSON null — `:json` encodes `:null` as `null`
  # but the Elixir atom `nil` as the string "nil".
  defp frame_size(nil, nil), do: {:null, :null}

  defp frame_size(width, height) when is_nil(width) or is_nil(height) do
    raise ArgumentError,
          "start_frame_stream: pass both :width and :height as nil for native " <>
            "resolution, or neither (got width: #{inspect(width)}, height: #{inspect(height)})"
  end

  defp frame_size(width, height), do: {width, height}

  @doc """
  Stop the camera frame stream. Safe to call when no stream is active. The
  visible preview (if `start_preview/2` was called separately) is left untouched.
  """
  @spec stop_frame_stream(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_frame_stream(socket) do
    :mob_camera_nif.camera_stop_frame_stream()
    socket
  end

  @snap_defaults %{facing: :back, flash: :off, max_size: 1600, quality: 85}

  @typedoc "Why a `snap/1` failed, as delivered in `{:camera, :snap_error, reason}`."
  @type snap_error :: :no_camera | :permission | :busy | :background | String.t()

  @doc """
  Take one still photo headlessly: no preview, no shutter, no user action.

  Opens the camera, lets auto-exposure, autofocus and white balance settle (so
  the frame isn't black or dark), takes one still, releases the camera and
  writes an upright JPEG to the app's cache (Android) or temp (iOS) directory.
  Works from any process — a screen, a GenServer, a Task — and the result goes
  to **the calling process**:

      {:camera, :snapped, %{path: path, width: w, height: h, facing: :back | :front}}
      {:camera, :snap_error, reason}

  `reason` is one of:

    * `:no_camera` — no camera with that facing (always on the iOS simulator).
    * `:permission` — camera permission not granted. `snap/1` never prompts;
      request `:camera` first with `Mob.Permissions.request/2`.
    * `:busy` — another snap is in progress, the camera is held elsewhere
      (Android, after the camera stayed in use until the timeout), or, on iOS,
      the shared `start_preview/2` / `start_frame_stream/2` session is running
      (it keeps running after `stop_frame_stream/1` until `stop_preview/1`) or
      a `capture_photo/2` / `capture_video/2` picker is open.
    * `:background` — the app has no foreground activity/scene; neither OS
      gives the camera to a backgrounded app.
    * a `String.t()` describing a platform error (including the native
      10-second timeout).

  Exactly one of the two messages arrives for every `:ok`.

  The pixels are rotated upright (the sensor/EXIF orientation is applied to
  them and the file is written with orientation 1), so whatever reads the file
  sees it the right way up without honouring EXIF. `width`/`height` are the
  written image's. `path` is a temp file: move it if you want to keep it.

  On Android, a running `Mob.UI.camera_preview/1` pauses while the snap holds
  the camera and resumes after.

  ## Options

    * `:facing` — `:back` (default) or `:front`.
    * `:flash` — `:off` (default), `:on` or `:auto`. Ignored by a camera with no
      flash.
    * `:max_size` — longest side of the written image in pixels (default
      `1600`); a smaller sensor image is not upscaled. `nil` keeps the sensor's
      full resolution.
    * `:quality` — JPEG quality, `1..100` (default `85`).

  Returns `:ok` once the request is handed to the native side, or
  `{:error, {:invalid_option, key, value}}` / `{:error, {:unknown_option, key}}`
  for bad options (nothing is sent then). `{:error, :unavailable}` means the
  native bridge never registered (Android).

  Requires the `:camera` permission.
  """
  @spec snap(keyword()) :: :ok | {:error, term()}
  def snap(opts \\ []) do
    with {:ok, native_opts} <- snap_opts(opts) do
      :mob_camera_nif.camera_snap(:json.encode(native_opts))
    end
  end

  @doc """
  Validate `snap/1` options and build the map sent to the NIF. Pure function
  exposed so tests can pin defaults and serialisation without the NIF.

      iex> MobCamera.snap_opts(facing: :front)
      {:ok, %{"facing" => "front", "flash" => "off", "max_size" => 1600, "quality" => 85}}
  """
  @spec snap_opts(keyword()) ::
          {:ok, map()} | {:error, {:invalid_option, atom(), term()} | {:unknown_option, term()}}
  def snap_opts(opts) when is_list(opts) do
    Enum.reduce_while(opts, {:ok, @snap_defaults}, fn
      {key, value}, {:ok, acc} when is_map_key(@snap_defaults, key) ->
        if valid_snap_opt?(key, value),
          do: {:cont, {:ok, Map.put(acc, key, value)}},
          else: {:halt, {:error, {:invalid_option, key, value}}}

      {key, _value}, _acc ->
        {:halt, {:error, {:unknown_option, key}}}

      other, _acc ->
        {:halt, {:error, {:unknown_option, other}}}
    end)
    |> case do
      {:ok, o} ->
        {:ok,
         %{
           "facing" => Atom.to_string(o.facing),
           "flash" => Atom.to_string(o.flash),
           # `:json` encodes `:null` as null; Elixir nil would become "nil".
           "max_size" => o.max_size || :null,
           "quality" => o.quality
         }}

      error ->
        error
    end
  end

  defp valid_snap_opt?(:facing, v), do: v in [:back, :front]
  defp valid_snap_opt?(:flash, v), do: v in [:off, :on, :auto]
  defp valid_snap_opt?(:max_size, v), do: is_nil(v) or (is_integer(v) and v > 0)
  defp valid_snap_opt?(:quality, v), do: is_integer(v) and v in 1..100
end
