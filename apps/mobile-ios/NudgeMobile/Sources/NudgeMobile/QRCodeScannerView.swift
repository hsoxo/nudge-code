import AVFoundation
import SwiftUI
import UIKit

struct QRCodeScannerView: UIViewControllerRepresentable {
    var onScan: @MainActor (String) -> Void
    var onError: @MainActor (QRCodeScannerError) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onScan = onScan
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {
        uiViewController.onScan = onScan
        uiViewController.onError = onError
    }
}

enum QRCodeScannerError: Error, Equatable, Sendable {
    case cameraUnavailable
    case permissionDenied
    case configurationFailed

    var message: String {
        switch self {
        case .cameraUnavailable:
            "Camera is unavailable"
        case .permissionDenied:
            "Camera permission is required"
        case .configurationFailed:
            "Unable to start QR scanner"
        }
    }
}

@MainActor
final class QRCodeScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onScan: (@MainActor (String) -> Void)?
    var onError: (@MainActor (QRCodeScannerError) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didEmitResult = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureIfAllowed()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        didEmitResult = false
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    private func configureIfAllowed() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        self?.configureSession()
                        self?.startSession()
                    } else {
                        self?.emitError(.permissionDenied)
                    }
                }
            }
        case .denied, .restricted:
            emitError(.permissionDenied)
        @unknown default:
            emitError(.configurationFailed)
        }
    }

    private func configureSession() {
        guard previewLayer == nil else {
            return
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            emitError(.cameraUnavailable)
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureMetadataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                emitError(.configurationFailed)
                return
            }
            session.beginConfiguration()
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.insertSublayer(layer, at: 0)
            previewLayer = layer
        } catch {
            emitError(.configurationFailed)
        }
    }

    private func startSession() {
        guard previewLayer != nil, !session.isRunning else {
            return
        }
        session.startRunning()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didEmitResult,
              let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              object.type == .qr,
              let value = object.stringValue
        else {
            return
        }
        didEmitResult = true
        session.stopRunning()
        onScan?(value)
    }

    private func emitError(_ error: QRCodeScannerError) {
        onError?(error)
    }
}
