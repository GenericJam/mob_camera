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

  ## Live frame stream

  For real-time work (object detection, AR, custom filters) `start_frame_stream/2`
  delivers per-frame pixel data as messages:

      handle_info({:camera, :frame, %{bytes: bin, width: w, height: h,
                                       format: :rgb_f32,
                                       timestamp_ms: t, dropped: n}}, socket)

  The native side handles resize + format conversion (vImage on iOS, CameraX
  ImageAnalysis + Bitmap on Android) so the BEAM never sees raw camera buffers.
  Late frames are dropped natively so the mailbox can't unbounded-grow.

  ## Live preview

  Pair `start_preview/2` with a `Mob.UI.camera_preview/1` component (in mob core)
  in your render tree to show the feed:

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
  Start streaming camera frames to the calling process. Frames arrive as
  messages of shape:

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
      (YOLO-friendly). Pass `nil` for both to receive the camera's native
      resolution. Mismatched aspect ratios are center-cropped on the long axis
      before scaling. Capped at ~4 MP to keep the BEAM mailbox bounded.

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
    %{
      "width" => Keyword.get(opts, :width, 640),
      "height" => Keyword.get(opts, :height, 640),
      "format" => Keyword.get(opts, :format, :rgb_f32) |> Atom.to_string(),
      "facing" => Keyword.get(opts, :facing, :back) |> Atom.to_string(),
      "throttle_ms" => Keyword.get(opts, :throttle_ms, 0)
    }
  end

  @doc """
  Stop the camera frame stream. Safe to call when no stream is active. The
  visible preview (if `start_preview/2` was called separately) is left untouched.
  """
  @spec stop_frame_stream(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_frame_stream(socket) do
    :mob_camera_nif.camera_stop_frame_stream()
    socket
  end
end
