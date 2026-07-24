import AVFoundation
import SwiftUI
import UIKit

struct CameraView: View {
    let onPhotoData: (Data) async throws -> Bool
    let onSuccess: () -> Void
    let onBack: () -> Void

    @State private var state: CameraState = .requestingPermission
    @State private var errorText = "Could not start the camera."
    @State private var controller: CameraController?

    var body: some View {
        ZStack {
            if let controller, state.allowsPreview {
                CameraPreviewView(session: controller.session)
                    .ignoresSafeArea()
            } else {
                Color.black.opacity(0.9)
                    .ignoresSafeArea()
            }

            switch state {
            case .requestingPermission, .configuring:
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
            case .processing:
                processingView
            case .denied:
                permissionView
            case .failed:
                failedView
            case .ready, .capturing:
                cameraControls
            }
        }
        .task {
            await prepareCamera()
        }
        .onDisappear {
            controller?.stop()
        }
    }

    private var cameraControls: some View {
        VStack {
            HStack {
                Button("Back") {
                    controller?.stop()
                    onBack()
                }
                .disabled(state == .capturing)
                .padding()
                .background(.regularMaterial, in: Capsule())

                Spacer()
            }
            .padding()

            Spacer()

            Button {
                Task { await takePhoto() }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(.white)
                        .frame(width: 62, height: 62)
                }
            }
            .disabled(state != .ready)
            .padding(.bottom, 34)
        }
    }

    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.4)
            Text("Processing…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Text("Camera access is off.")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Allow camera access in Settings to take a photo.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)

            Button("Open Settings") {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            }
            .buttonStyle(.borderedProminent)

            Button("Back") { onBack() }
                .foregroundStyle(.white)
        }
        .padding()
    }

    private var failedView: some View {
        VStack(spacing: 16) {
            Text(errorText)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                Task { await prepareCamera() }
            }
            .buttonStyle(.borderedProminent)

            Button("Back") { onBack() }
                .foregroundStyle(.white)
        }
        .padding()
    }

    private func prepareCamera() async {
        state = .requestingPermission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await configureCamera()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            granted ? await configureCamera() : (state = .denied)
        case .denied, .restricted:
            state = .denied
        @unknown default:
            state = .failed
        }
    }

    private func configureCamera() async {
        state = .configuring
        let controller = CameraController()
        do {
            try await controller.configure()
            self.controller = controller
            controller.start()
            state = .ready
        } catch {
            errorText = error.localizedDescription
            state = .failed
        }
    }

    private func takePhoto() async {
        guard state == .ready, let controller else { return }
        state = .capturing
        do {
            let data = try await controller.capturePhoto()
            state = .processing
            controller.stop()
            if try await onPhotoData(data) {
                onSuccess()
            } else {
                errorText = "Another import is already running."
                state = .failed
            }
        } catch {
            errorText = error.localizedDescription
            state = .failed
        }
    }
}

private enum CameraState {
    case requestingPermission
    case configuring
    case ready
    case capturing
    case processing
    case denied
    case failed

    var allowsPreview: Bool {
        switch self {
        case .configuring, .ready, .capturing:
            true
        case .requestingPermission, .processing, .denied, .failed:
            false
        }
    }
}

private final class CameraController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "dap.camera.session")
    private var delegate: PhotoDelegate?

    func configure() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.session.beginConfiguration()
                    self.session.sessionPreset = .photo
                    defer { self.session.commitConfiguration() }

                    guard
                        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    else {
                        throw CameraError.unavailable
                    }

                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                        throw CameraError.configurationFailed
                    }
                    self.session.addInput(input)
                    self.session.addOutput(self.output)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() {
        queue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoDelegate { [weak self] result in
                self?.delegate = nil
                continuation.resume(with: result)
            }
            self.delegate = delegate
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            completion(.success(data))
        } else {
            completion(.failure(CameraError.captureFailed))
        }
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}

private enum CameraError: LocalizedError {
    case unavailable
    case configurationFailed
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Camera is not available."
        case .configurationFailed: "Could not configure the camera."
        case .captureFailed: "Could not capture the photo."
        }
    }
}
