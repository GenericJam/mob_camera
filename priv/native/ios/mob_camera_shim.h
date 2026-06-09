/* mob_camera_shim.h — bridging declarations so the plugin's Swift preview view
 * can reach the C global the plugin's mob_camera_nif.m owns.
 *
 * g_preview_session is defined (non-static) in mob_camera_nif.m. The plugin's
 * Swift (MobCameraPreviewView.swift) displays it via an AVCaptureVideoPreviewLayer.
 * For Swift to see the C global, this header must reach the app's Swift bridging
 * header during the plugin Swift compile (the plugin-swift bridging-header wiring
 * is the one open build item — see EXTRACTION.md).
 */
#import <AVFoundation/AVFoundation.h>

extern AVCaptureSession *_Nullable g_preview_session;
