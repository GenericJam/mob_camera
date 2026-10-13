defmodule MobCamera.RefusedCallTest do
  # Not async: the stub NIF goes into the :mob_camera app env, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule UnregisteredBridgeNif do
    def camera_capture_photo(_quality), do: {:error, :bridge_not_registered}
    def camera_capture_video(_max_duration), do: {:error, :bridge_not_registered}
    def camera_start_preview(_json), do: {:error, :bridge_not_registered}
    def camera_stop_preview, do: {:error, :bridge_not_registered}
    def camera_start_frame_stream(_json), do: {:error, :bridge_not_registered}
    def camera_stop_frame_stream, do: {:error, :bridge_not_registered}
  end

  defmodule AcceptingNif do
    def camera_capture_photo(_quality), do: :ok
    def camera_capture_video(_max_duration), do: :ok
    def camera_start_preview(_json), do: :ok
    def camera_stop_preview, do: :ok
    def camera_start_frame_stream(_json), do: :ok
    def camera_stop_frame_stream, do: :ok
  end

  @calls [
    {"capture_photo/2", &MobCamera.capture_photo/1},
    {"capture_video/2", &MobCamera.capture_video/1},
    {"start_preview/2", &MobCamera.start_preview/1},
    {"stop_preview/1", &MobCamera.stop_preview/1},
    {"start_frame_stream/2", &MobCamera.start_frame_stream/1},
    {"stop_frame_stream/1", &MobCamera.stop_frame_stream/1}
  ]

  setup do
    previous = Application.fetch_env(:mob_camera, :nif)

    on_exit(fn ->
      case previous do
        {:ok, nif} -> Application.put_env(:mob_camera, :nif, nif)
        :error -> Application.delete_env(:mob_camera, :nif)
      end
    end)

    %{socket: Mob.Socket.new(__MODULE__)}
  end

  test "a refused call is logged with the function and reason, and still returns the socket",
       %{socket: socket} do
    Application.put_env(:mob_camera, :nif, UnregisteredBridgeNif)

    for {name, fun} <- @calls do
      log = capture_log(fn -> assert fun.(socket) == socket end)
      assert log =~ "MobCamera.#{name}"
      assert log =~ ":bridge_not_registered"
    end
  end

  test "an accepted call logs nothing", %{socket: socket} do
    Application.put_env(:mob_camera, :nif, AcceptingNif)

    for {_name, fun} <- @calls do
      assert capture_log(fn -> assert fun.(socket) == socket end) == ""
    end
  end
end
