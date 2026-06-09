//! mob_camera_nif — Android camera tier-1/2 ZIG plugin NIF.
//!
//! Extracted from mob-core's `mob_nif.zig`: the 6 camera NIFs + the
//! mob_deliver_camera_frame term builder. The Kotlin side is the plugin-owned
//! bridge class `io.mob.camera.MobCameraBridge` (CameraX: TakePicture /
//! CaptureVideo activity contracts + ImageAnalysis frame stream, ARGB->BGRA
//! repack). Capture/frame results arrive back via the exported deliver thunks.
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const CamMethods = struct {
    capture_photo: jni.JMethodID = null,
    capture_video: jni.JMethodID = null,
    start_preview: jni.JMethodID = null,
    stop_preview: jni.JMethodID = null,
    start_frame_stream: jni.JMethodID = null,
    stop_frame_stream: jni.JMethodID = null,
};

var g_cam: CamMethods = .{};
var g_cam_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method ids ───────────
export fn Java_io_mob_camera_MobCameraBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_cam_cls = jni.newGlobalRef(jenv, cls);
    if (g_cam_cls == null) return;
    g_cam.capture_photo = jni.getStaticMethodID(jenv, cls, "camera_capture_photo", "(JLjava/lang/String;)V");
    g_cam.capture_video = jni.getStaticMethodID(jenv, cls, "camera_capture_video", "(JLjava/lang/String;)V");
    g_cam.start_preview = jni.getStaticMethodID(jenv, cls, "camera_start_preview", "(JLjava/lang/String;)V");
    g_cam.stop_preview = jni.getStaticMethodID(jenv, cls, "camera_stop_preview", "()V");
    g_cam.start_frame_stream = jni.getStaticMethodID(jenv, cls, "camera_start_frame_stream", "(JLjava/lang/String;)V");
    g_cam.stop_frame_stream = jni.getStaticMethodID(jenv, cls, "camera_stop_frame_stream", "()V");
}

// ── Thread-attach + pid round-trip helpers (mirror mob-core / location) ───
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

/// Call `MobCameraBridge.<method>(pid_long, arg)` — async; results land later
/// via the deliver thunks. Returns :ok unconditionally.
fn callBridgePidStr(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid, arg: ?[*:0]const u8) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jarg: jni.JString = if (arg) |a| jni.newStringUTF(jenv, a) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, g_cam_cls, method, pidToJlong(pid), jarg);
    if (jarg != null) jni.deleteLocalRef(jenv, jarg);
    detachIfAttached(attached);
    return erts.ok(env);
}

/// Call a no-arg static void bridge method.
fn callBridgeVoid(env: ?*erts.ErlNifEnv, method: jni.JMethodID) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    jenv.*.CallStaticVoidMethod.?(jenv, g_cam_cls, method);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Inbound delivery — Kotlin's ImageAnalysis callback calls this ─────────
// Builds {:camera, :frame, %{bytes, width, height, format, timestamp_ms, dropped}}.
export fn Java_io_mob_camera_MobCameraBridge_nativeDeliverCameraFrame(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    bytes: [*]const u8,
    nbytes: usize,
    width: c_int,
    height: c_int,
    format: [*:0]const u8,
    timestamp_ms: jni.JLong,
    dropped: jni.JLong,
) callconv(.c) void {
    _ = jenv;
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    var pix: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(nbytes, &pix) == 0) return;
    @memcpy(pix.data[0..nbytes], bytes[0..nbytes]);

    const keys = [_]erts.ERL_NIF_TERM{
        erts.atom(env, "bytes"),
        erts.atom(env, "width"),
        erts.atom(env, "height"),
        erts.atom(env, "format"),
        erts.atom(env, "timestamp_ms"),
        erts.atom(env, "dropped"),
    };
    const vals = [_]erts.ERL_NIF_TERM{
        erts.enif_make_binary(env, &pix),
        erts.enif_make_int(env, width),
        erts.enif_make_int(env, height),
        erts.atom(env, format),
        erts.enif_make_int64(env, timestamp_ms),
        erts.enif_make_int64(env, dropped),
    };
    const map = erts.makeMap(env, &keys, &vals) orelse return;
    const msg = erts.makeTuple(env, .{ erts.atom(env, "camera"), erts.atom(env, "frame"), map });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIFs ──────────────────────────────────────────────────────────────────
fn nif_camera_capture_photo(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var q_buf: [16]u8 = @splat(0);
    jni.copyZ(&q_buf, "high");
    _ = erts.enif_get_atom(env, argv[0], &q_buf, q_buf.len, erts.ERL_NIF_LATIN1);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_cam.capture_photo, pid, jni.asCStr(&q_buf));
}

fn nif_camera_capture_video(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var dur: c_int = 60;
    _ = erts.enif_get_int(env, argv[0], &dur);
    var d_buf: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&d_buf, "{d}", .{dur}) catch {};
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_cam.capture_video, pid, jni.asCStr(&d_buf));
}

fn nif_camera_start_preview(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = jni.getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = jni.binToCString(bin) orelse return erts.atom(env, "error");
    defer jni.freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_cam.start_preview, pid, json);
}

fn nif_camera_stop_preview(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return callBridgeVoid(env, g_cam.stop_preview);
}

fn nif_camera_start_frame_stream(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    const bin = jni.getBinOrIolist(env, argv[0]) orelse return erts.badarg(env);
    const json = jni.binToCString(bin) orelse return erts.atom(env, "error");
    defer jni.freeCString(json);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_cam.start_frame_stream, pid, json);
}

fn nif_camera_stop_frame_stream(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    return callBridgeVoid(env, g_cam.stop_frame_stream);
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "camera_capture_photo", .arity = 1, .fptr = nif_camera_capture_photo, .flags = 0 },
    .{ .name = "camera_capture_video", .arity = 1, .fptr = nif_camera_capture_video, .flags = 0 },
    .{ .name = "camera_start_preview", .arity = 1, .fptr = nif_camera_start_preview, .flags = 0 },
    .{ .name = "camera_stop_preview", .arity = 0, .fptr = nif_camera_stop_preview, .flags = 0 },
    .{ .name = "camera_start_frame_stream", .arity = 1, .fptr = nif_camera_start_frame_stream, .flags = 0 },
    .{ .name = "camera_stop_frame_stream", .arity = 0, .fptr = nif_camera_stop_frame_stream, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_camera_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_camera_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
