import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct CameraView: View {
    let library: PhotoLibraryViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var state: CameraState = .requestingPermission
    @State private var errorText = "Could not start the camera."
    @State private var controller: CameraController?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var isFlashOn = false
    @State private var isFlashAvailable = false
    @State private var isZoomed = false
    @State private var previewPitchClass: PitchClass = .c

    private var latestCoverData: Data? {
        library.items.first.flatMap { library.coverDataByID[$0.id] }
    }

    private var latestPhotoID: UUID? {
        library.items.first?.id
    }

    private var isShutterProcessing: Bool {
        state == .processing && selectedPhoto == nil
    }

    private var isGalleryDismissDisabled: Bool {
        state == .capturing || state == .processing
    }

    private var previewPalette: ColorPalette {
        RetroCoverRenderer.tonalPalette(for: previewPitchClass)
    }

    var body: some View {
        ZStack {
            if let controller, state.allowsPreview || isShutterProcessing {
                CameraPreviewView(controller: controller)
                    .ignoresSafeArea(edges: .horizontal)
                    .padding(.top, 98)
                    .padding(.bottom, 189)
            } else {
                Color.cameraChrome
                    .ignoresSafeArea()
            }

            cameraChrome

            overlayContent
        }
        .interactiveDismissDisabled()
        .task {
            await prepareCamera()
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhoto,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: isPhotoPickerPresented) { _, isPresented in
            if isPresented {
                controller?.stop()
            } else if selectedPhoto == nil, state == .ready {
                controller?.start()
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task { await importPickedPhoto(newValue) }
        }
        .onDisappear {
            controller?.onPitchClassSample = nil
            controller?.stop()
        }
        .statusBarHidden(true)
    }

    private var cameraChrome: some View {
        VStack {
            Color.cameraChrome
                .frame(height: 98)
                .ignoresSafeArea(edges: .top)

            Spacer()

            VStack(spacing: 13) {
                commandRow
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(rgbColor: previewPalette.shadow),
                                Color(rgbColor: previewPalette.dark),
                                Color(rgbColor: previewPalette.base),
                                Color(rgbColor: previewPalette.highlight),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 37)
                    .padding(.horizontal, 16)
                    .accessibilityHidden(true)

                HStack {
                    Button {
                        guard !isGalleryDismissDisabled else { return }
                        controller?.stop()
                        dismiss()
                    } label: {
                        galleryThumbnail
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(!isGalleryDismissDisabled)

                    Spacer()

                    shutterButton

                    Spacer()

                    Button {
                        Task { await switchCamera() }
                    } label: {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .font(.system(size: 28, weight: .semibold))
                            .frame(width: 57, height: 57)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .allowsHitTesting(state == .ready)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 26)
            }
            .padding(.top, 6)
            .background(Color.cameraChrome.ignoresSafeArea(edges: .bottom))
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        switch state {
        case .requestingPermission, .configuring:
            ProgressView()
                .tint(.white)
                .scaleEffect(1.4)
        case .processing:
            if isShutterProcessing {
                EmptyView()
            } else {
                processingView
            }
        case .denied:
            permissionView
        case .failed:
            failedView
        case .ready, .capturing:
            EmptyView()
        }
    }

    private var commandRow: some View {
        HStack(spacing: 16) {
            Button {
                guard state == .ready else { return }
                isPhotoPickerPresented = true
            } label: {
                Image(systemName: "photo.badge.plus.fill")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(state == .ready)

            Button {
                guard state == .ready, isFlashAvailable else { return }
                isFlashOn.toggle()
            } label: {
                Image(systemName: "bolt.fill")
                    .frame(width: 42, height: 42)
            }
            .foregroundStyle(isFlashOn ? .yellow : .white)
            .allowsHitTesting(state == .ready && isFlashAvailable)

            Button {
                Task { await toggleZoom() }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 42, height: 42)
            }
            .foregroundStyle(isZoomed ? .yellow : .white)
            .allowsHitTesting(state == .ready)
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
    }

    private var shutterButton: some View {
        Button {
            Task { await takePhoto() }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 97, height: 97)
                if state == .capturing || isShutterProcessing {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 82, height: 82)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 82, height: 82)
                }
            }
        }
        .allowsHitTesting(state == .ready)
    }

    private var galleryThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white.opacity(0.18))
                .frame(width: 56, height: 57)
                .offset(x: 3, y: -2)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white.opacity(0.42))
                .frame(width: 50, height: 57)
                .offset(x: 1, y: 1)
            thumbnailImage
                .frame(width: 56, height: 57)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            if isShutterProcessing {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.black.opacity(0.22))
                    .frame(width: 56, height: 57)
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.8)
            }
        }
        .accessibilityLabel("Return to Gallery")
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
            controller.onPitchClassSample = { pitchClass in
                Task { @MainActor in
                    if reduceMotion {
                        previewPitchClass = pitchClass
                    } else {
                        withAnimation(.easeOut(duration: 0.35)) {
                            previewPitchClass = pitchClass
                        }
                    }
                }
            }
            self.controller?.onPitchClassSample = nil
            self.controller = controller
            controller.start()
            isFlashOn = false
            isZoomed = false
            isFlashAvailable = controller.isFlashAvailable
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
            let flashMode: AVCaptureDevice.FlashMode = isFlashOn ? .on : .off
            let data = try await controller.capturePhoto(flashMode: flashMode)
            state = .processing
            if try await library.importPhotoData(data) {
                state = .ready
            } else {
                controller.stop()
                errorText = "Another import is already running."
                state = .failed
            }
        } catch {
            controller.stop()
            errorText = error.localizedDescription
            state = .failed
        }
    }

    private func importPickedPhoto(_ item: PhotosPickerItem) async {
        guard state == .ready else { return }
        state = .processing
        controller?.stop()
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw CameraError.captureFailed
            }
            if try await library.importPhotoData(data) {
                selectedPhoto = nil
                dismiss()
            } else {
                errorText = "Another import is already running."
                state = .failed
            }
        } catch {
            selectedPhoto = nil
            errorText = error.localizedDescription
            state = .failed
            controller?.start()
        }
    }

    private func switchCamera() async {
        guard state == .ready, let controller else { return }
        do {
            try await controller.switchCamera()
            isZoomed = false
            isFlashAvailable = controller.isFlashAvailable
            if !isFlashAvailable {
                isFlashOn = false
            }
        } catch {
            errorText = error.localizedDescription
            state = .failed
        }
    }

    private func toggleZoom() async {
        guard state == .ready, let controller else { return }
        let requestedFactor: CGFloat = isZoomed ? 1 : 2
        do {
            let appliedFactor = try await controller.setZoomFactor(requestedFactor)
            isZoomed = appliedFactor > 1.0
        } catch {
            errorText = error.localizedDescription
            state = .failed
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let latestCoverData, let image = UIImage(data: latestCoverData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .id(latestPhotoID)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88), value: latestPhotoID)
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white.opacity(0.84))
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

    private static let colorSamplesPerAxis = 12
    private static let colorSampleInterval: CFAbsoluteTime = 0.25

    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dap.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "dap.camera.video-output")
    private var delegate: PhotoDelegate?
    private var device: AVCaptureDevice?
    private var currentInput: AVCaptureDeviceInput?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var lastColorSampleTime: CFAbsoluteTime = 0
    private var pendingPitchClass: PitchClass?
    private var publishedPitchClass: PitchClass?

    var onPitchClassSample: (@Sendable (PitchClass) -> Void)? {
        didSet {
            if onPitchClassSample == nil {
                resetPitchClassSamplingState()
            }
        }
    }

    var isFlashAvailable: Bool {
        guard let device else { return false }
        return device.hasFlash && supportsFlashMode(.on)
    }

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

                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    ]
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)

                    self.session.addInput(input)
                    self.session.addOutput(self.output)
                    if self.session.canAddOutput(self.videoOutput) {
                        self.session.addOutput(self.videoOutput)
                    }
                    self.device = device
                    self.currentInput = input
                    self.resetPitchClassSamplingState()
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

    func switchCamera() async throws {
        let newDevice = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard
                        let currentInput = self.currentInput,
                        let currentDevice = self.device
                    else {
                        throw CameraError.configurationFailed
                    }

                    let newPosition: AVCaptureDevice.Position = currentDevice.position == .back ? .front : .back
                    guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else {
                        throw CameraError.unavailable
                    }

                    let newInput = try AVCaptureDeviceInput(device: newDevice)

                    self.session.beginConfiguration()
                    self.session.removeInput(currentInput)

                    guard self.session.canAddInput(newInput) else {
                        if self.session.canAddInput(currentInput) {
                            self.session.addInput(currentInput)
                        }
                        self.session.commitConfiguration()
                        throw CameraError.configurationFailed
                    }

                    self.session.addInput(newInput)
                    self.session.commitConfiguration()

                    do {
                        _ = try self.setZoomFactor(1, on: newDevice)
                    } catch {
                        self.session.beginConfiguration()
                        self.session.removeInput(newInput)
                        if self.session.canAddInput(currentInput) {
                            self.session.addInput(currentInput)
                        }
                        self.session.commitConfiguration()
                        throw error
                    }

                    self.currentInput = newInput
                    self.device = newDevice
                    self.resetPitchClassSamplingState()
                    continuation.resume(returning: newDevice)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        await MainActor.run {
            self.rebuildRotationCoordinator(for: newDevice)
        }
    }

    func setZoomFactor(_ requestedFactor: CGFloat) async throws -> CGFloat {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let device = self.device else {
                        throw CameraError.configurationFailed
                    }
                    let appliedFactor = try self.setZoomFactor(requestedFactor, on: device)
                    continuation.resume(returning: appliedFactor)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor
    func attachPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
        if self.previewLayer === previewLayer {
            if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview {
                applyPreviewRotation(angle)
            }
            return
        }

        self.previewLayer = previewLayer
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        rebuildRotationCoordinator(for: device)
    }

    @MainActor
    func capturePhoto(flashMode: AVCaptureDevice.FlashMode) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoDelegate { [weak self] result in
                self?.delegate = nil
                continuation.resume(with: result)
            }
            self.delegate = delegate
            applyCaptureRotation()
            let settings = AVCapturePhotoSettings()
            let resolvedFlashMode: AVCaptureDevice.FlashMode = supportsFlashMode(flashMode) ? flashMode : .off
            if supportsFlashMode(resolvedFlashMode) {
                settings.flashMode = resolvedFlashMode
            }
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    @MainActor
    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection else { return }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        applyPreviewMirroring(on: connection)
    }

    @MainActor
    private func applyCaptureRotation() {
        guard let connection = output.connection(with: .video) else { return }
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        disableMirroring(on: connection)
    }

    @MainActor
    private func disableMirroring(on connection: AVCaptureConnection) {
        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }

    @MainActor
    private func rebuildRotationCoordinator(for device: AVCaptureDevice?) {
        previewRotationObservation = nil
        rotationCoordinator = nil

        guard let previewLayer, let device else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                self?.applyPreviewRotation(angle)
            }
        }
    }

    @MainActor
    private func applyPreviewMirroring(on connection: AVCaptureConnection) {
        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = device?.position == .front
    }

    private func supportsFlashMode(_ mode: AVCaptureDevice.FlashMode) -> Bool {
        output.supportedFlashModes.contains(mode)
    }

    private func resetPitchClassSamplingState() {
        lastColorSampleTime = 0
        pendingPitchClass = nil
        publishedPitchClass = nil
    }

    private func setZoomFactor(_ requestedFactor: CGFloat, on device: AVCaptureDevice) throws -> CGFloat {
        let appliedFactor = min(max(requestedFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = appliedFactor
        return device.videoZoomFactor
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

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        guard output === videoOutput, onPitchClassSample != nil else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastColorSampleTime >= Self.colorSampleInterval else { return }
        lastColorSampleTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let candidatePitchClass = samplePitchClass(from: pixelBuffer)

        guard candidatePitchClass != publishedPitchClass else {
            pendingPitchClass = nil
            return
        }

        guard pendingPitchClass == candidatePitchClass else {
            pendingPitchClass = candidatePitchClass
            return
        }

        pendingPitchClass = nil
        publishedPitchClass = candidatePitchClass
        onPitchClassSample?(candidatePitchClass)
    }

    private func samplePitchClass(from pixelBuffer: CVPixelBuffer) -> PitchClass {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return .c }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let samplesPerAxis = Self.colorSamplesPerAxis
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var sampleCount = 0.0

        for yIndex in 0 ..< samplesPerAxis {
            let y = min(height - 1, ((yIndex * 2 + 1) * height) / (samplesPerAxis * 2))
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)

            for xIndex in 0 ..< samplesPerAxis {
                let x = min(width - 1, ((xIndex * 2 + 1) * width) / (samplesPerAxis * 2))
                let pixel = row.advanced(by: x * 4)
                blue += Double(pixel[0]) / 255
                green += Double(pixel[1]) / 255
                red += Double(pixel[2]) / 255
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return .c }

        let hue = hueDegrees(red: red / sampleCount, green: green / sampleCount, blue: blue / sampleCount)
        return PitchClass(rawValue: RetroCoverRenderer.pitchClass(forHueDegrees: hue))!
    }

    private func hueDegrees(red: Double, green: Double, blue: Double) -> Double {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        let delta = maxComponent - minComponent

        if delta == 0 { return 0 }
        if maxComponent == red {
            return (60 * ((green - blue) / delta) + 360).truncatingRemainder(dividingBy: 360)
        }
        if maxComponent == green {
            return 60 * ((blue - red) / delta + 2)
        }
        return 60 * ((red - green) / delta + 4)
    }
}

private struct CameraPreviewView: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        controller.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        controller.attachPreviewLayer(uiView.previewLayer)
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

private extension Color {
    static let cameraChrome = Color.black

    init(rgbColor: RGBColor) {
        self.init(
            red: Double(rgbColor.red) / 255,
            green: Double(rgbColor.green) / 255,
            blue: Double(rgbColor.blue) / 255
        )
    }
}
