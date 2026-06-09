// MobCameraPreviewView — iOS live-preview component for the camera plugin.
//
// Extracted from mob-core ios/MobRootView.swift. In core, camera_preview was a
// builtin renderer node (`.cameraPreview`); here it's a plugin native view
// registered under the key "MobCamera_PreviewView" (the manifest ui_components
// entry), resolved by `MobCamera.preview/1` via Mob.UI.native_view.
//
// Displays the shared AVCaptureSession the NIF's start_preview/2 activates
// (g_preview_session, owned by mob_camera_nif.m; reached via mob_camera_shim.h).
import AVFoundation
import SwiftUI
import UIKit

// Custom UIView whose backing layer is an AVCaptureVideoPreviewLayer. UIKit keeps
// the layer frame in sync with the view bounds automatically.
private class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var cameraLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct MobCameraPreviewView: UIViewRepresentable {
    let facing: String

    init(facing: String = "back") { self.facing = facing }

    func makeUIView(context: Context) -> UIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.cameraLayer.videoGravity = .resizeAspectFill
        view.cameraLayer.session = g_preview_session
        rotatePreviewConnection(view: view)
        context.coordinator.startObserving(view: view)
        return view
    }

    // Pin the preview to portrait so what the user sees matches the upright frame
    // the stream ships — the sensor is landscape-native.
    private func rotatePreviewConnection(view: CameraPreviewUIView) {
        guard let conn = view.cameraLayer.connection else { return }
        if #available(iOS 17.0, *) {
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
        } else if conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
    }

    func updateUIView(_ view: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        private var observer: NSObjectProtocol?
        private weak var hostView: CameraPreviewUIView?

        func startObserving(view: UIView) {
            hostView = view as? CameraPreviewUIView
            observer = NotificationCenter.default.addObserver(
                forName: .mobCameraSessionChanged, object: nil, queue: .main
            ) { [weak self] _ in
                guard let view = self?.hostView else { return }
                view.cameraLayer.session = g_preview_session
                if let conn = view.cameraLayer.connection {
                    if #available(iOS 17.0, *) {
                        if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                    } else if conn.isVideoOrientationSupported {
                        conn.videoOrientation = .portrait
                    }
                }
            }
        }

        deinit {
            if let obs = observer { NotificationCenter.default.removeObserver(obs) }
        }
    }
}

extension Notification.Name {
    static let mobCameraSessionChanged = Notification.Name("MobCameraSessionChanged")
}
