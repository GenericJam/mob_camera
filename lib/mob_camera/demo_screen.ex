defmodule MobCamera.DemoScreen do
  @moduledoc """
  A ready-to-run sample screen exercising `MobCamera`, shipped so a generated
  app can kick the tires the moment the plugin is activated. Declared in the
  plugin manifest's `:screens`, so the host's home can surface it by route
  without writing any code. Delete it (and the manifest entry) in a real app.
  """
  use Mob.Screen

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       status: "Tap to capture a photo",
       last_path: nil,
       pending: nil
     )}
  end

  @impl true
  def render(assigns) do
    tap_capture = {self(), :capture}
    tap_snap = {self(), :snap}

    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="Camera" text_size={:lg} text_color={:on_surface} padding={:space_sm} />
        <Text text={assigns.status} text_size={:sm} text_color={:primary} padding={4} />
        <Spacer size={8} />
        <Text text={path_text(assigns)} text_size={:sm} text_color={:muted} padding={4} />
        <Spacer size={16} />
        <Button text="Capture photo" background={:primary} text_color={:on_primary} padding={:space_md} fill_width={true} on_tap={tap_capture} />
        <Spacer size={8} />
        <Button text="Snap (no shutter)" background={:primary} text_color={:on_primary} padding={:space_md} fill_width={true} on_tap={tap_snap} />
      </Column>
    </Scroll>
    """
  end

  defp path_text(%{last_path: nil}), do: "No photo captured yet"
  defp path_text(%{last_path: path}), do: "Saved: #{Path.basename(path)}"

  @impl true
  def handle_info({:tap, action}, socket) when action in [:capture, :snap] do
    {:noreply,
     socket
     |> Mob.Permissions.request(:camera)
     |> Mob.Socket.assign(pending: action, status: "Requesting camera permission…")}
  end

  def handle_info({:permission, :camera, :granted}, %{assigns: %{pending: :snap}} = socket) do
    status =
      case MobCamera.snap() do
        :ok -> "Snapping…"
        {:error, reason} -> "Snap refused: #{inspect(reason)}"
      end

    {:noreply, Mob.Socket.assign(socket, pending: nil, status: status)}
  end

  def handle_info({:permission, :camera, :granted}, socket) do
    {:noreply,
     socket
     |> MobCamera.capture_photo()
     |> Mob.Socket.assign(pending: nil, status: "Opening camera…")}
  end

  def handle_info({:permission, :camera, :denied}, socket) do
    {:noreply, Mob.Socket.assign(socket, pending: nil, status: "Camera permission denied")}
  end

  def handle_info({:camera, :photo, %{path: path}}, socket) do
    {:noreply, Mob.Socket.assign(socket, last_path: path, status: "Captured")}
  end

  def handle_info({:camera, :snapped, %{path: path, width: w, height: h}}, socket) do
    {:noreply, Mob.Socket.assign(socket, last_path: path, status: "Snapped #{w}×#{h}")}
  end

  def handle_info({:camera, :snap_error, reason}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "Snap failed: #{inspect(reason)}")}
  end

  def handle_info({:camera, :cancelled}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "Capture cancelled")}
  end
end
