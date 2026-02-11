//
//  CameraPreviewView.swift
//  Nobody Cares
//
//  UIViewControllerRepresentable bridge for AVFoundation camera.
//  Embeds CameraPreviewController into SwiftUI.
//

import SwiftUI

struct CameraPreviewView: UIViewControllerRepresentable {
    let onCapture: (CaptureResult) -> Void
    let onError: (String) -> Void

    /// Reference to the controller so parent views can trigger capture/recording
    @Binding var controller: CameraPreviewController?

    func makeUIViewController(context: Context) -> CameraPreviewController {
        let vc = CameraPreviewController()
        vc.onCapture = onCapture
        vc.onError = onError
        DispatchQueue.main.async {
            controller = vc
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraPreviewController, context: Context) {
        // No dynamic updates needed
    }
}
