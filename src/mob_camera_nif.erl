%% mob_camera_nif — Erlang NIF module for the camera tier-1/2 plugin.
%%
%% iOS: priv/native/ios/mob_camera_nif.m (Objective-C: UIImagePickerController
%% capture, a shared AVCaptureSession for live preview + frame streaming with a
%% vImage resize/convert path, and the :camera permission flow). Android:
%% priv/native/jni/mob_camera_nif.zig bridging to CameraX via the
%% io.mob.camera.MobCameraBridge Kotlin bridge. Both register this module via
%% ERL_NIF_INIT and are statically linked into the host binary on device. On a
%% host dev build neither is linked, so on_load tolerates the failure and the
%% NIFs fall back to nif_error until the native merge links one.
-module(mob_camera_nif).
-export([
    camera_capture_photo/1,
    camera_capture_video/1,
    camera_start_preview/1,
    camera_stop_preview/0,
    camera_start_frame_stream/1,
    camera_stop_frame_stream/0
]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_camera_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

camera_capture_photo(_Quality) ->
    erlang:nif_error(nif_not_loaded).

camera_capture_video(_MaxDuration) ->
    erlang:nif_error(nif_not_loaded).

camera_start_preview(_Json) ->
    erlang:nif_error(nif_not_loaded).

camera_stop_preview() ->
    erlang:nif_error(nif_not_loaded).

camera_start_frame_stream(_Json) ->
    erlang:nif_error(nif_not_loaded).

camera_stop_frame_stream() ->
    erlang:nif_error(nif_not_loaded).
