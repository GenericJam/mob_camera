/* mob_camera_nif — iOS camera tier-1/2 plugin NIF (Objective-C).
 *
 * Extracted from mob-core ios/mob_nif.m: UIImagePickerController capture, a
 * shared AVCaptureSession for live preview + frame streaming (vImage resize +
 * BGRA->RGB f32), and the :camera permission flow. Self-contained — core's
 * mob_send2 / mob_root_vc are private statics, so this ships its own
 * (cam_send2 / cam_root_vc); the :camera permission handler registers with
 * core's runtime permission registry (mob_register_permission_handler, an
 * exported core symbol linked into the same static binary). Compiled as ObjC
 * (-fobjc-arc) via the plugin objc-NIF path (manifest lang: :objc).
 *
 * g_preview_session is intentionally a non-static global so the plugin's
 * MobCameraPreviewView.swift can `extern` and display it.
 */
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <erl_nif.h>

/* Defined in core mob's ios/mob_nif.m, linked into the same static binary. */
extern void mob_register_permission_handler(const char *cap, void (*fn)(ErlNifPid));

// Self-contained {atom, atom} send (core's mob_send2 is a private static).
static void cam_send2(const ErlNifPid *pid, const char *a1, const char *a2) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, a1), enif_make_atom(e, a2));
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

// Root view controller for presenting the capture picker (core's mob_root_vc
// is a private static).
static UIViewController *cam_root_vc(void) {
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
      UIWindowScene *ws = (UIWindowScene *)scene;
      UIWindow *w = ws.keyWindow ?: ws.windows.firstObject;
      if (w.rootViewController)
        return w.rootViewController;
    }
  }
  return nil;
}

// ── :camera permission (registered with core's registry at NIF load) ──────
static void cam_send_permission(ErlNifPid pid, const char *status) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "permission"),
                                      enif_make_atom(e, "camera"), enif_make_atom(e, status));
  enif_send(NULL, &pid, e, msg);
  enif_free_env(e);
}

static void mob_camera_request_permission(ErlNifPid pid) {
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                           completionHandler:^(BOOL granted) {
                             cam_send_permission(pid, granted ? "granted" : "denied");
                           }];
}

// ── Camera capture ────────────────────────────────────────────────────────

@interface MobCameraDelegate
    : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property(nonatomic) ErlNifPid pid;
@property(nonatomic) BOOL isVideo;
@end

static MobCameraDelegate *g_camera_delegate = nil;

@implementation MobCameraDelegate
- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    ErlNifPid p = self.pid;
    BOOL isVid = self.isVideo;
    g_camera_delegate = nil;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      ErlNifEnv *e = enif_alloc_env();
      ERL_NIF_TERM msg;
      if (!isVid) {
          UIImage *img = info[UIImagePickerControllerOriginalImage];
          NSString *tmp = [NSTemporaryDirectory()
              stringByAppendingPathComponent:[NSString stringWithFormat:@"mob_photo_%@.jpg",
                                                                        [NSUUID UUID].UUIDString]];
          [UIImageJPEGRepresentation(img, 0.9) writeToFile:tmp atomically:YES];
          const char *path = tmp.UTF8String;
          ErlNifBinary pbin;
          enif_alloc_binary(strlen(path), &pbin);
          memcpy(pbin.data, path, strlen(path));
          ERL_NIF_TERM keys[3] = {enif_make_atom(e, "path"), enif_make_atom(e, "width"),
                                  enif_make_atom(e, "height")};
          ERL_NIF_TERM vals[3] = {enif_make_binary(e, &pbin), enif_make_int(e, (int)img.size.width),
                                  enif_make_int(e, (int)img.size.height)};
          ERL_NIF_TERM map;
          enif_make_map_from_arrays(e, keys, vals, 3, &map);
          msg = enif_make_tuple3(e, enif_make_atom(e, "camera"), enif_make_atom(e, "photo"), map);
      } else {
          NSURL *url = info[UIImagePickerControllerMediaURL];
          NSString *tmp = [NSTemporaryDirectory()
              stringByAppendingPathComponent:[NSString stringWithFormat:@"mob_video_%@.mp4",
                                                                        [NSUUID UUID].UUIDString]];
          if (url)
              [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:tmp error:nil];
          const char *path = tmp.UTF8String;
          ErlNifBinary pbin;
          enif_alloc_binary(strlen(path), &pbin);
          memcpy(pbin.data, path, strlen(path));
          ERL_NIF_TERM keys[2] = {enif_make_atom(e, "path"), enif_make_atom(e, "duration")};
          ERL_NIF_TERM vals[2] = {enif_make_binary(e, &pbin), enif_make_double(e, 0.0)};
          ERL_NIF_TERM map;
          enif_make_map_from_arrays(e, keys, vals, 2, &map);
          msg = enif_make_tuple3(e, enif_make_atom(e, "camera"), enif_make_atom(e, "video"), map);
      }
      enif_send(NULL, &p, e, msg);
      enif_free_env(e);
    });
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
    cam_send2(&_pid, "camera", "cancelled");
    g_camera_delegate = nil;
}
@end

static void present_image_picker(ErlNifPid pid, UIImagePickerControllerSourceType src,
                                 UIImagePickerControllerCameraCaptureMode mode) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (![UIImagePickerController isSourceTypeAvailable:src]) {
          cam_send2(&pid, "camera", "not_available");
          return;
      }
      UIImagePickerController *picker = [[UIImagePickerController alloc] init];
      picker.sourceType = src;
      picker.cameraCaptureMode = mode;
      if (mode == UIImagePickerControllerCameraCaptureModeVideo) {
          picker.mediaTypes = @[ UTTypeMovie.identifier ];
      }
      g_camera_delegate = [[MobCameraDelegate alloc] init];
      g_camera_delegate.pid = pid;
      g_camera_delegate.isVideo = (mode == UIImagePickerControllerCameraCaptureModeVideo);
      picker.delegate = g_camera_delegate;

      [cam_root_vc() presentViewController:picker animated:YES completion:nil];
    });
}

static ERL_NIF_TERM nif_camera_capture_photo(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    enif_self(env, &pid);
    present_image_picker(pid, UIImagePickerControllerSourceTypeCamera,
                         UIImagePickerControllerCameraCaptureModePhoto);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_camera_capture_video(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    enif_self(env, &pid);
    int max_sec = 60;
    enif_get_int(env, argv[0], &max_sec);
    present_image_picker(pid, UIImagePickerControllerSourceTypeCamera,
                         UIImagePickerControllerCameraCaptureModeVideo);
    return enif_make_atom(env, "ok");
}

// ── Camera preview ────────────────────────────────────────────────────────

// One shared AVCaptureSession per app — iOS won't allow two sessions on
// the same physical camera, and a single session can carry multiple
// outputs (preview layer + AVCaptureVideoDataOutput). Both
// `start_preview` and `start_frame_stream` configure this same session;
// the serial queue serializes all mutation so they can be called in
// either order.
AVCaptureSession *g_preview_session = nil; // exported name preserved for SwiftUI
static AVCaptureDeviceInput *g_camera_input = nil;
static NSString *g_camera_facing = nil;
static dispatch_queue_t g_camera_queue = NULL;

static dispatch_queue_t mob_camera_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      g_camera_queue = dispatch_queue_create("io.mob.camera.config", DISPATCH_QUEUE_SERIAL);
    });
    return g_camera_queue;
}

// Configure session input for the requested facing. Idempotent — if the
// facing already matches, leaves the input alone. Must be called from
// the serial camera queue.
static BOOL mob_camera_ensure_session(NSString *facing) {
    if (!g_preview_session) {
        g_preview_session = [[AVCaptureSession alloc] init];
        g_preview_session.sessionPreset = AVCaptureSessionPresetHigh;
        NSLog(@"[mob/camera] created shared AVCaptureSession");
    }
    if (g_camera_input && [g_camera_facing isEqualToString:facing]) {
        return YES;
    }

    AVCaptureDevicePosition position = [facing isEqualToString:@"front"]
                                           ? AVCaptureDevicePositionFront
                                           : AVCaptureDevicePositionBack;
    AVCaptureDevice *device =
        [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                           mediaType:AVMediaTypeVideo
                                            position:position];
    if (!device) {
        NSLog(@"[mob/camera] no camera device for facing=%@", facing);
        return NO;
    }
    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
    if (!input) {
        NSLog(@"[mob/camera] AVCaptureDeviceInput failed: %@", err);
        return NO;
    }

    [g_preview_session beginConfiguration];
    if (g_camera_input) {
        [g_preview_session removeInput:g_camera_input];
        g_camera_input = nil;
    }
    if ([g_preview_session canAddInput:input]) {
        [g_preview_session addInput:input];
        g_camera_input = input;
        g_camera_facing = [facing copy];
        NSLog(@"[mob/camera] added input facing=%@", facing);
    } else {
        NSLog(@"[mob/camera] canAddInput=NO for facing=%@", facing);
        [g_preview_session commitConfiguration];
        return NO;
    }
    [g_preview_session commitConfiguration];
    return YES;
}

static ERL_NIF_TERM nif_camera_start_preview(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    NSString *facing = @"back";
    if (enif_inspect_binary(env, argv[0], &bin) ||
        enif_inspect_iolist_as_binary(env, argv[0], &bin)) {
        NSString *json = [[NSString alloc] initWithBytes:bin.data
                                                  length:bin.size
                                                encoding:NSUTF8StringEncoding];
        NSDictionary *opts =
            [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                            options:0
                                              error:nil];
        if ([opts[@"facing"] isEqualToString:@"front"])
            facing = @"front";
    }

    dispatch_async(mob_camera_queue(), ^{
      if (!mob_camera_ensure_session(facing))
          return;
      if (!g_preview_session.isRunning) {
          [g_preview_session startRunning];
          NSLog(@"[mob/camera] session startRunning (from preview)");
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MobCameraSessionChanged"
                                                            object:nil];
      });
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_camera_stop_preview(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      AVCaptureSession *old = g_preview_session;
      g_preview_session = nil;
      [[NSNotificationCenter defaultCenter] postNotificationName:@"MobCameraSessionChanged"
                                                          object:nil];
      // Stop the session off the main queue so we don't block the UI.
      if (old)
          dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [old stopRunning];
          });
    });
    return enif_make_atom(env, "ok");
}

// ── Camera frame stream ───────────────────────────────────────────────────
// Delivers per-frame pixel data to a BEAM process as messages of shape:
//
//   {camera, frame, #{bytes, width, height, format, timestamp_ms, dropped}}
//
// The capture session here is independent of the preview session — they
// each own their own AVCaptureDeviceInput on the same camera device (an
// arrangement AVFoundation allows). This means start_frame_stream can run
// headlessly (no visible preview) and start_preview can run without ML
// inference. The two compose cleanly when both are active.
//
// vImage handles resize + format conversion on the capture queue so the
// BEAM mailbox never sees raw camera buffers. Late frames are discarded
// at the AVFoundation layer (alwaysDiscardsLateVideoFrames=YES is the
// iOS default and we leave it on); throttle_ms adds an additional
// software gate when callers want a slower delivery rate than the
// camera's native 30fps.

@interface MobFrameDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation MobFrameDelegate {
    ErlNifPid _receiver_pid;
    int _target_width;
    int _target_height;
    NSString *_format;
    int _throttle_ms;
    uint64_t _last_delivered_ms;
    uint64_t _dropped_count;
}

- (instancetype)initWithPid:(ErlNifPid)pid
                      width:(int)width
                     height:(int)height
                     format:(NSString *)format
                 throttleMs:(int)throttleMs {
    if ((self = [super init])) {
        _receiver_pid = pid;
        _target_width = width;
        _target_height = height;
        _format = format;
        _throttle_ms = throttleMs;
        _last_delivered_ms = 0;
        _dropped_count = 0;
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    uint64_t now_ms = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);

    // Software-side throttle: gate at most one frame per `throttle_ms`.
    // Frames arriving faster get counted in `dropped` for visibility.
    if (_throttle_ms > 0 && (now_ms - _last_delivered_ms) < (uint64_t)_throttle_ms) {
        _dropped_count++;
        return;
    }

    CVPixelBufferRef pixbuf = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixbuf) {
        _dropped_count++;
        return;
    }

    CVPixelBufferLockBaseAddress(pixbuf, kCVPixelBufferLock_ReadOnly);

    size_t src_w = CVPixelBufferGetWidth(pixbuf);
    size_t src_h = CVPixelBufferGetHeight(pixbuf);
    void *src_base = CVPixelBufferGetBaseAddress(pixbuf);
    size_t src_stride = CVPixelBufferGetBytesPerRow(pixbuf);

    // Center-crop the source to the destination aspect ratio so the
    // resize doesn't squash a 16:9 camera frame into a 1:1 tensor.
    // For a 1920×1080 source and a 640×640 destination: take a centered
    // 1080×1080 square (cuts 420 px from each side), then scale to
    // 640×640.
    int dst_w = _target_width;
    int dst_h = _target_height;

    double src_aspect = (double)src_w / (double)src_h;
    double dst_aspect = (double)dst_w / (double)dst_h;

    size_t crop_x = 0, crop_y = 0, crop_w = src_w, crop_h = src_h;
    if (src_aspect > dst_aspect) {
        // Source is wider than destination — crop horizontally.
        crop_w = (size_t)((double)src_h * dst_aspect);
        crop_x = (src_w - crop_w) / 2;
    } else if (src_aspect < dst_aspect) {
        // Source is taller than destination — crop vertically.
        crop_h = (size_t)((double)src_w / dst_aspect);
        crop_y = (src_h - crop_h) / 2;
    }

    // vImage source descriptor pointing at the (possibly-offset) crop region.
    // Bytes per pixel for BGRA = 4.
    vImage_Buffer vsrc = {
        .data = (uint8_t *)src_base + (crop_y * src_stride) + (crop_x * 4),
        .height = crop_h,
        .width = crop_w,
        .rowBytes = src_stride,
    };

    // Intermediate BGRA8 destination at the target size.
    uint8_t *dst_bgra = malloc((size_t)dst_w * dst_h * 4);
    vImage_Buffer vdst = {
        .data = dst_bgra,
        .height = (vImagePixelCount)dst_h,
        .width = (vImagePixelCount)dst_w,
        .rowBytes = (size_t)dst_w * 4,
    };

    vImageScale_ARGB8888(&vsrc, &vdst, NULL, kvImageHighQualityResampling);

    CVPixelBufferUnlockBaseAddress(pixbuf, kCVPixelBufferLock_ReadOnly);

    // Pack into the requested output format.
    ErlNifEnv *msg_env = enif_alloc_env();
    ErlNifBinary out_bin;

    if ([_format isEqualToString:@"rgb_f32"]) {
        size_t pixel_count = (size_t)dst_w * (size_t)dst_h;
        enif_alloc_binary(pixel_count * 3 * sizeof(float), &out_bin);
        float *out = (float *)out_bin.data;

        // vImage delivers BGRA8 in iOS-native channel order. Convert to
        // interleaved RGB f32 in [0, 1]. Straight loop is fine — vImage
        // doesn't ship a BGRA→RGB-interleaved-f32 single-call so this
        // would otherwise be three passes (BGRA→RGBA→planar→combine).
        // The single-pass loop is ~1ms on a 640×640 frame.
        for (size_t i = 0; i < pixel_count; i++) {
            uint8_t b = dst_bgra[i * 4 + 0];
            uint8_t g = dst_bgra[i * 4 + 1];
            uint8_t r = dst_bgra[i * 4 + 2];
            out[i * 3 + 0] = (float)r / 255.0f;
            out[i * 3 + 1] = (float)g / 255.0f;
            out[i * 3 + 2] = (float)b / 255.0f;
        }
    } else {
        // :bgra_u8 — copy bytes directly.
        enif_alloc_binary((size_t)dst_w * dst_h * 4, &out_bin);
        memcpy(out_bin.data, dst_bgra, (size_t)dst_w * dst_h * 4);
    }
    free(dst_bgra);

    // Build the result map. Keys are atoms so the Elixir side gets
    // %{bytes:, width:, height:, format:, timestamp_ms:, dropped:}.
    ERL_NIF_TERM bytes_term = enif_make_binary(msg_env, &out_bin);
    ERL_NIF_TERM map = enif_make_new_map(msg_env);
    enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "bytes"), bytes_term, &map);
    enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "width"), enif_make_int(msg_env, dst_w),
                      &map);
    enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "height"),
                      enif_make_int(msg_env, dst_h), &map);
    enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "format"),
                      enif_make_atom(msg_env, [_format UTF8String]), &map);
    enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "timestamp_ms"),
                      enif_make_uint64(msg_env, now_ms), &map);
    enif_make_map_put(msg_env, map, enif_make_atom(msg_env, "dropped"),
                      enif_make_uint64(msg_env, _dropped_count), &map);

    ERL_NIF_TERM tagged = enif_make_tuple3(msg_env, enif_make_atom(msg_env, "camera"),
                                           enif_make_atom(msg_env, "frame"), map);

    // enif_send is documented thread-safe; this delegate callback runs
    // on the capture session's serial queue, not the BEAM scheduler.
    // Passing NULL for caller_env is the standard pattern from a
    // non-BEAM thread.
    enif_send(NULL, &_receiver_pid, msg_env, tagged);
    enif_free_env(msg_env);

    _last_delivered_ms = now_ms;
    _dropped_count = 0;
}

@end

// Frame stream output + delegate attach to the shared g_preview_session.
// AVCaptureVideoDataOutput does NOT retain its delegate, so g_frame_delegate
// is the canonical strong reference that keeps it alive.
static AVCaptureVideoDataOutput *g_frame_output = nil;
static MobFrameDelegate *g_frame_delegate = nil;
static dispatch_queue_t g_frame_delivery_queue = NULL;

static ERL_NIF_TERM nif_camera_start_frame_stream(ErlNifEnv *env, int argc,
                                                  const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin)) {
        return enif_make_badarg(env);
    }

    NSString *json = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    NSDictionary *opts =
        [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                        options:0
                                          error:nil];

    int target_w = [(opts[@"width"] ?: @640) intValue];
    int target_h = [(opts[@"height"] ?: @640) intValue];
    NSString *facing = [opts[@"facing"] isEqualToString:@"front"] ? @"front" : @"back";
    NSString *format = [opts[@"format"] isEqualToString:@"bgra_u8"] ? @"bgra_u8" : @"rgb_f32";
    int throttle_ms = [(opts[@"throttle_ms"] ?: @0) intValue];

    // Cap pixel count to keep mailbox bounded. ~4 MP = 2048×2048.
    if ((int64_t)target_w * (int64_t)target_h > 4 * 1024 * 1024) {
        target_w = 2048;
        target_h = 2048;
    }

    ErlNifPid caller_pid;
    enif_self(env, &caller_pid);

    NSLog(@"[mob/camera] start_frame_stream w=%d h=%d facing=%@ format=%@ throttle=%d", target_w,
          target_h, facing, format, throttle_ms);

    if (!g_frame_delivery_queue) {
        g_frame_delivery_queue =
            dispatch_queue_create("io.mob.camera.frame_delivery", DISPATCH_QUEUE_SERIAL);
    }

    dispatch_async(mob_camera_queue(), ^{
      if (!mob_camera_ensure_session(facing)) {
          NSLog(@"[mob/camera] ensure_session failed");
          return;
      }

      [g_preview_session beginConfiguration];
      if (g_frame_output) {
          [g_preview_session removeOutput:g_frame_output];
          g_frame_output = nil;
          g_frame_delegate = nil;
      }

      AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
      output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
      output.alwaysDiscardsLateVideoFrames = YES;

      MobFrameDelegate *delegate = [[MobFrameDelegate alloc] initWithPid:caller_pid
                                                                   width:target_w
                                                                  height:target_h
                                                                  format:format
                                                              throttleMs:throttle_ms];
      // Per Apple: setSampleBufferDelegate:queue: does NOT retain the
      // delegate. Hold our own strong ref in g_frame_delegate.
      [output setSampleBufferDelegate:delegate queue:g_frame_delivery_queue];

      if ([g_preview_session canAddOutput:output]) {
          [g_preview_session addOutput:output];
          g_frame_output = output;
          g_frame_delegate = delegate;
          NSLog(@"[mob/camera] added AVCaptureVideoDataOutput");
      } else {
          NSLog(@"[mob/camera] canAddOutput=NO");
      }
      [g_preview_session commitConfiguration];

      // Rotate the connection to portrait so the model sees upright
      // pixels. The sensor's native orientation is landscape-right;
      // without this, YOLO sees a 90°-rotated scene and misclassifies
      // everything (a jar becomes a horizontal bar that looks like
      // "laptop"). 90° rotation maps landscape sensor → portrait
      // upright. videoRotationAngle is iOS 17+; older builds get the
      // deprecated videoOrientation as a fallback.
      AVCaptureConnection *conn = [output connectionWithMediaType:AVMediaTypeVideo];
      if (conn) {
          if (@available(iOS 17.0, *)) {
              if ([conn isVideoRotationAngleSupported:90.0])
                  conn.videoRotationAngle = 90.0;
          } else {
              if ([conn isVideoOrientationSupported])
                  conn.videoOrientation = AVCaptureVideoOrientationPortrait;
          }
          NSLog(@"[mob/camera] frame output rotated to portrait");
      }

      if (!g_preview_session.isRunning) {
          [g_preview_session startRunning];
          NSLog(@"[mob/camera] session startRunning (from frame_stream)");
      } else {
          NSLog(@"[mob/camera] session already running");
      }
    });

    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_camera_stop_frame_stream(ErlNifEnv *env, int argc,
                                                 const ERL_NIF_TERM argv[]) {
    dispatch_async(mob_camera_queue(), ^{
      if (g_frame_output) {
          [g_preview_session beginConfiguration];
          [g_preview_session removeOutput:g_frame_output];
          [g_preview_session commitConfiguration];
          g_frame_output = nil;
          g_frame_delegate = nil;
          NSLog(@"[mob/camera] stop_frame_stream removed output");
      }
    });
    return enif_make_atom(env, "ok");
}

// ── Registration ──────────────────────────────────────────────────────────
static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  (void)env;
  (void)priv_data;
  (void)load_info;
  mob_register_permission_handler("camera", mob_camera_request_permission);
  return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"camera_capture_photo", 1, nif_camera_capture_photo, 0},
    {"camera_capture_video", 1, nif_camera_capture_video, 0},
    {"camera_start_preview", 1, nif_camera_start_preview, 0},
    {"camera_stop_preview", 0, nif_camera_stop_preview, 0},
    {"camera_start_frame_stream", 1, nif_camera_start_frame_stream, 0},
    {"camera_stop_frame_stream", 0, nif_camera_stop_frame_stream, 0},
};

ERL_NIF_INIT(mob_camera_nif, nif_funcs, load, NULL, NULL, NULL)
