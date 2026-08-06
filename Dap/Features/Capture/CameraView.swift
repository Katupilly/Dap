import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import Vision

struct CameraView: View {
    let library: PhotoLibraryViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var state: CameraState = .requestingPermission
    @State private var errorText = "Could not start the camera."
    @State private var controller: CameraController?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isPhotoPickerPresented = false
    @State private var isCameraObscured = false
    @State private var isFlashOn = false
    @State private var isFlashAvailable = false
    @State private var isZoomed = false
    @State private var isSwitchingCamera = false
    @State private var previewPitchClass: PitchClass = .c
    @State private var isPortraitPreviewMode = false
    @State private var importCompletion: ImportCompletion?
    @State private var importVisualPhase: ImportVisualPhase = .idle
    @State private var importAnimationStartDate = Date()
    @State private var completionStartDate = Date()
    @State private var completionStartDashLength: CGFloat = 0.16
    @State private var completionStartRotation = 0.0
    @State private var visualGeneration = 0
    @State private var completionDismissTask: Task<Void, Never>?
    @State private var completionHaptic: UIImpactFeedbackGenerator?
    @State private var isExiting = false

    private var latestCoverData: Data? {
        library.items.first.flatMap { library.coverDataByID[$0.id] }
    }

    private var latestPhotoID: UUID? {
        library.items.first?.id
    }

    private var isShutterProcessing: Bool {
        state == .processing && selectedPhotos.isEmpty
    }

    private var isGalleryDismissDisabled: Bool {
        state == .capturing || state == .processing
    }

    private var previewPalette: ColorPalette {
        if isPortraitPreviewMode {
            return ColorPalette(
                shadow: .black,
                dark: .black,
                base: .black,
                highlight: .white
            )
        }
        return RetroCoverRenderer.tonalPalette(for: previewPitchClass)
    }

    var body: some View {
        ZStack {
            if let controller, state.allowsPreview || isShutterProcessing {
                CameraPreviewView(controller: controller)
                    .ignoresSafeArea(edges: .horizontal)
                    .padding(.top, 98)
                    .padding(.bottom, 189)
                    .background(Color.cameraChrome)
                    .overlay {
                        if isCameraObscured {
                            Color.cameraChrome
                                .ignoresSafeArea()
                                .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.12)))
                        }
                    }
            } else {
                Color.cameraChrome
                    .ignoresSafeArea()
            }

            cameraChrome

            overlayContent
        }
        .opacity(isExiting ? 0 : 1)
        .interactiveDismissDisabled()
        .task {
            await prepareCamera()
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotos,
            maxSelectionCount: 20,
            selectionBehavior: .ordered,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: isPhotoPickerPresented) { _, isPresented in
            if isPresented {
                isCameraObscured = true
                controller?.stop()
            } else {
                isCameraObscured = false
                if selectedPhotos.isEmpty, state == .ready {
                    controller?.start()
                }
            }
        }
        .onChange(of: selectedPhotos) { _, newValue in
            guard !newValue.isEmpty, state == .ready, !library.isImporting else { return }
            Task { await importPickedPhotos(newValue) }
        }
        .onChange(of: library.isImporting) { _, isImporting in
            if isImporting {
                beginImportVisuals()
            }
        }
        .onDisappear {
            controller?.onPitchClassSample = nil
            controller?.onPortraitPreviewMode = nil
            isPortraitPreviewMode = false
            controller?.stop()
            invalidateVisualCompletion()
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
                CameraLavaLampView(
                    palette: previewPalette,
                    reduceMotion: reduceMotion
                )
                .frame(height: 37)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 5,
                        style: .continuous
                    )
                )
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

                    CaptureFlipCameraButton(isEnabled: state == .ready && !isSwitchingCamera) {
                        Task { await switchCamera() }
                    }
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
                guard state == .ready, !library.isImporting else { return }
                isPhotoPickerPresented = true
            } label: {
                Image(systemName: "photo.badge.plus.fill")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(state == .ready && !library.isImporting)

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
                ImportRingView(
                    phase: library.isImporting ? .importing : importVisualPhase,
                    animationStartDate: importAnimationStartDate,
                    completionStartDate: completionStartDate,
                    completionStartDashLength: completionStartDashLength,
                    completionStartRotation: completionStartRotation,
                    reduceMotion: reduceMotion
                )
                Circle()
                    .fill(library.isImporting ? .white.opacity(0.42) : .white)
                    .frame(width: 82, height: 82)
            }
        }
        .disabled(state != .ready || library.isImporting || importVisualPhase == .completing)
        .accessibilityLabel("Take Photo")
        .accessibilityValue(library.isImporting ? "Import in progress" : "")
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

    @ViewBuilder
    private var processingView: some View {
        if library.isImporting, library.batchTotalCount > 0 {
            ImportShimmerText(
                text: processingStatusText,
                reduceMotion: reduceMotion
            )
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

            Button(importCompletion?.showsDoneAction == true ? "Done" : "Try Again") {
                if importCompletion?.showsDoneAction == true {
                    dismiss()
                } else {
                    importCompletion = nil
                    Task { await prepareCamera() }
                }
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
        isPortraitPreviewMode = false
        let controller = CameraController()
        do {
            try await controller.configure()
            controller.onPitchClassSample = { pitchClass in
                Task { @MainActor in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                        previewPitchClass = pitchClass
                    }
                }
            }
            controller.onPortraitPreviewMode = { isPortrait in
                Task { @MainActor in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                        isPortraitPreviewMode = isPortrait
                    }
                }
            }
            self.controller?.onPitchClassSample = nil
            self.controller?.onPortraitPreviewMode = nil
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
                resetImportVisuals()
                state = .ready
            } else {
                resetImportVisuals()
                controller.stop()
                errorText = "Another import is already running."
                state = .failed
            }
        } catch {
            resetImportVisuals()
            controller.stop()
            errorText = error.localizedDescription
            state = .failed
        }
    }

    private var batchProgressDisplayCount: Int {
        guard library.batchTotalCount > 0 else { return 0 }
        return min(
            max(1, library.batchCompletedCount + (library.batchCompletedCount < library.batchTotalCount ? 1 : 0)),
            library.batchTotalCount
        )
    }

    private var processingStatusText: String {
        guard library.isImporting, library.batchTotalCount > 0 else {
            return "Processing…"
        }
        return "Importing \(batchProgressDisplayCount) of \(library.batchTotalCount)"
    }

    private func importPickedPhotos(_ items: [PhotosPickerItem]) async {
        guard state == .ready, !items.isEmpty, !library.isImporting else { return }
        state = .processing
        controller?.stop()

        importCompletion = nil
        let totalCount = items.count
        let result = await library.importPhotos(from: items)
        selectedPhotos = []

        if result.importedCount == totalCount {
            completeImportVisually()
        } else if result.importedCount > 0 {
            resetImportVisuals()
            importCompletion = .partial
            errorText = "Imported \(result.importedCount) of \(totalCount) photos"
            state = .failed
        } else {
            resetImportVisuals()
            importCompletion = .failed
            errorText = totalCount == 1
                ? "Could not import the selected photo."
                : "Could not import the selected photos."
            state = .failed
            controller?.start()
        }
    }

    private func beginImportVisuals() {
        invalidateVisualCompletion()
        importVisualPhase = .importing
        importAnimationStartDate = Date()
    }

    private func completeImportVisually() {
        completionDismissTask?.cancel()
        completionDismissTask = nil
        completionHaptic = UIImpactFeedbackGenerator(style: .rigid)
        completionHaptic?.prepare()

        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(importAnimationStartDate))
        completionStartDashLength = ImportRingView.activeDashLength(at: elapsed)
        completionStartRotation = ImportRingView.activeRotation(at: elapsed)
        completionStartDate = now
        importVisualPhase = .completing
        visualGeneration += 1

        let generation = visualGeneration
        let visualDuration = reduceMotion ? 0 : ImportRingView.completionDuration
        completionDismissTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(visualDuration))
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                generation == visualGeneration,
                importVisualPhase == .completing
            else {
                return
            }

            completionHaptic?.impactOccurred(intensity: 0.65)
            completionHaptic = nil
            guard !reduceMotion else {
                completionDismissTask = nil
                importVisualPhase = .idle
                dismiss()
                return
            }

            let exitDuration = 0.12
            withAnimation(.easeOut(duration: exitDuration)) {
                isExiting = true
            }

            do {
                try await Task.sleep(for: .seconds(exitDuration))
            } catch {
                return
            }

            guard
                !Task.isCancelled,
                generation == visualGeneration,
                importVisualPhase == .completing,
                isExiting
            else {
                return
            }

            completionDismissTask = nil
            importVisualPhase = .idle
            dismiss()
        }
    }

    private func resetImportVisuals() {
        invalidateVisualCompletion()
    }

    private func invalidateVisualCompletion() {
        completionDismissTask?.cancel()
        completionDismissTask = nil
        completionHaptic = nil
        visualGeneration += 1
        importVisualPhase = .idle
        isExiting = false
    }

    private func switchCamera() async {
        guard state == .ready, let controller, !isSwitchingCamera else { return }
        isSwitchingCamera = true
        defer { isSwitchingCamera = false }
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

private enum ImportVisualPhase: Equatable {
    case idle
    case importing
    case completing
}

private struct ImportRingView: View {
    static let completionDuration: TimeInterval = 0.42

    let phase: ImportVisualPhase
    let animationStartDate: Date
    let completionStartDate: Date
    let completionStartDashLength: CGFloat
    let completionStartRotation: Double
    let reduceMotion: Bool

    var body: some View {
        Group {
            switch phase {
            case .idle:
                ring(trim: 1, rotation: 0)
            case .importing:
                importingRing
            case .completing:
                completionRing
            }
        }
        .frame(width: 97, height: 97)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var importingRing: some View {
        if reduceMotion {
            ring(trim: Self.activeDashLength(at: 0), rotation: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(animationStartDate))
                ring(
                    trim: Self.activeDashLength(at: elapsed),
                    rotation: Self.activeRotation(at: elapsed)
                )
            }
        }
    }

    @ViewBuilder
    private var completionRing: some View {
        if reduceMotion {
            ring(trim: 1, rotation: completionStartRotation)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(completionStartDate))
                let progress = min(elapsed / Self.completionDuration, 1)
                let easedProgress = progress * progress * (3 - 2 * progress)
                let trim = completionStartDashLength
                    + (1 - completionStartDashLength) * CGFloat(easedProgress)

                ring(trim: trim, rotation: completionStartRotation)
            }
        }
    }

    private func ring(trim: CGFloat, rotation: Double) -> some View {
        Circle()
            .trim(from: 0, to: min(max(trim, 0.01), 1))
            .stroke(
                .white,
                style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
    }

    static func activeDashLength(at time: TimeInterval) -> CGFloat {
        let cycleDuration = 1.1
        let cycleProgress = time.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        let easedProgress = 0.5 - 0.5 * cos(cycleProgress * .pi * 2)
        return 0.16 + 0.27 * CGFloat(easedProgress)
    }

    static func activeRotation(at time: TimeInterval) -> Double {
        (time / 1.25 * 360).truncatingRemainder(dividingBy: 360)
    }
}

private struct ImportShimmerText: View {
    let text: String
    let reduceMotion: Bool

    @State private var animationStartDate = Date()

    var body: some View {
        if reduceMotion {
            baseText
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let cycleDuration = 1.35
                let phase = context.date
                    .timeIntervalSince(animationStartDate)
                    .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration

                baseText
                    .overlay {
                        shimmerGradient(phase: CGFloat(phase))
                    }
            }
        }
    }

    private var baseText: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
            .accessibilityLabel(text)
    }

    private func shimmerGradient(phase: CGFloat) -> some View {
        let center = -0.24 + phase * 1.48
        let halfWidth = 0.16
        let start = min(max(center - halfWidth, 0), 1)
        let peak = min(max(center, 0), 1)
        let end = min(max(center + halfWidth, 0), 1)

        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: start),
                .init(color: .white.opacity(0.72), location: peak),
                .init(color: .clear, location: end),
                .init(color: .clear, location: 1),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
        .mask {
            Text(text)
                .font(.subheadline)
        }
        .accessibilityHidden(true)
    }
}

struct CaptureFlipCameraButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.trianglehead.2.clockwise")
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 57, height: 57)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .allowsHitTesting(isEnabled)
        .accessibilityLabel("Virar câmera")
        .accessibilityHint("Alterna entre a câmera traseira e a frontal.")
    }
}

private enum ImportCompletion {
    case partial
    case failed

    var showsDoneAction: Bool {
        switch self {
        case .partial:
            true
        case .failed:
            false
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

final class CameraController: NSObject, @unchecked Sendable {
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
    private var colorSampleCounter: Int = 0
    private var pendingPitchClass: PitchClass?
    private var pendingScore: Double = 0
    private var publishedPitchClass: PitchClass?
    private var publishedScore: Double = 0
    private var isPortraitPreviewMode = false
    private var pendingPortraitMode: Bool?
    private var pendingPortraitModeSamples = 0
    private let faceDetectionStride = 4
    private let scoreSwapMargin = 0.08

    var onPitchClassSample: (@Sendable (PitchClass) -> Void)? {
        didSet {
            if onPitchClassSample == nil {
                resetPitchClassSamplingState()
            }
        }
    }

    var onPortraitPreviewMode: (@Sendable (Bool) -> Void)?

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
            let wasPortraitPreviewMode = self.isPortraitPreviewMode
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.resetPitchClassSamplingState()
            if wasPortraitPreviewMode {
                self.onPortraitPreviewMode?(false)
            }
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
        colorSampleCounter = 0
        pendingPitchClass = nil
        pendingScore = 0
        publishedPitchClass = nil
        publishedScore = 0
        isPortraitPreviewMode = false
        pendingPortraitMode = nil
        pendingPortraitModeSamples = 0
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
        guard output === videoOutput,
              onPitchClassSample != nil || onPortraitPreviewMode != nil
        else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastColorSampleTime >= Self.colorSampleInterval else { return }
        lastColorSampleTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        colorSampleCounter += 1
        if colorSampleCounter.isMultiple(of: faceDetectionStride) {
            let faceArea = detectFaceAreaProportion(in: pixelBuffer)
            let shouldUsePortraitMode = faceArea >= 0.08
            if shouldUsePortraitMode == isPortraitPreviewMode {
                pendingPortraitMode = nil
                pendingPortraitModeSamples = 0
            } else if pendingPortraitMode == shouldUsePortraitMode {
                pendingPortraitModeSamples += 1
            } else {
                pendingPortraitMode = shouldUsePortraitMode
                pendingPortraitModeSamples = 1
            }

            if pendingPortraitMode == shouldUsePortraitMode,
               pendingPortraitModeSamples >= 2 {
                isPortraitPreviewMode = shouldUsePortraitMode
                pendingPortraitMode = nil
                pendingPortraitModeSamples = 0
                pendingPitchClass = nil
                pendingScore = 0
                publishedPitchClass = nil
                publishedScore = 0
                onPortraitPreviewMode?(shouldUsePortraitMode)
            }
        }

        guard !isPortraitPreviewMode, pendingPortraitMode != true else { return }

        let (candidatePitchClass, candidateScore) = samplePitchClass(from: pixelBuffer)

        if publishedPitchClass == nil {
            publishedPitchClass = candidatePitchClass
            publishedScore = candidateScore
            onPitchClassSample?(candidatePitchClass)
            pendingPitchClass = nil
            pendingScore = 0
            return
        }

        guard candidatePitchClass != publishedPitchClass else {
            pendingPitchClass = nil
            pendingScore = 0
            return
        }

        let dominant = max(candidateScore, publishedScore)
        let marginClear = dominant > 0
            && abs(candidateScore - publishedScore) / dominant >= scoreSwapMargin
        guard marginClear else {
            pendingPitchClass = nil
            pendingScore = 0
            return
        }

        guard pendingPitchClass == candidatePitchClass else {
            pendingPitchClass = candidatePitchClass
            pendingScore = candidateScore
            return
        }

        pendingPitchClass = nil
        pendingScore = 0
        publishedPitchClass = candidatePitchClass
        publishedScore = candidateScore
        onPitchClassSample?(candidatePitchClass)
    }

    private func detectFaceAreaProportion(in pixelBuffer: CVPixelBuffer) -> Double {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return 0
        }
        return min(1, (request.results ?? []).reduce(0) { result, observation in
            result + observation.boundingBox.width * observation.boundingBox.height
        })
    }

    private func samplePitchClass(from pixelBuffer: CVPixelBuffer) -> (PitchClass, Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return (.c, 0)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let samplesPerAxis = Self.colorSamplesPerAxis
        var sectorWeights = [Double](repeating: 0, count: 12)
        var globalWeight = 0.0

        for yIndex in 0 ..< samplesPerAxis {
            let y = min(height - 1, ((yIndex * 2 + 1) * height) / (samplesPerAxis * 2))
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)

            for xIndex in 0 ..< samplesPerAxis {
                let x = min(width - 1, ((xIndex * 2 + 1) * width) / (samplesPerAxis * 2))
                let pixel = row.advanced(by: x * 4)
                let blue = Double(pixel[0]) / 255
                let green = Double(pixel[1]) / 255
                let red = Double(pixel[2]) / 255
                let (hue, saturation) = hueSaturation(red: red, green: green, blue: blue)
                let weight = max(0, saturation - 0.10)
                guard weight > 0 else { continue }
                let sector = min(11, max(0, Int(hue / 30)))
                sectorWeights[sector] += weight
                globalWeight += weight
            }
        }

        guard globalWeight > 0 else { return (.c, 0) }
        guard let bestSector = sectorWeights.indices.max(by: {
            if sectorWeights[$0] != sectorWeights[$1] {
                return sectorWeights[$0] < sectorWeights[$1]
            }
            return $0 > $1
        }) else { return (.c, 0) }
        let score = sectorWeights[bestSector] / globalWeight
        let pitchClass = PhotoMusicPipeline.colorBasedRootPitchClass(
            fromHue: Double(bestSector * 30 + 15)
        )
        return (pitchClass, score)
    }

    private func hueSaturation(red: Double, green: Double, blue: Double) -> (hue: Double, saturation: Double) {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        let delta = maxComponent - minComponent
        let saturation = maxComponent == 0 ? 0 : delta / maxComponent
        if delta == 0 { return (0, saturation) }
        let hue: Double
        if maxComponent == red {
            hue = (60 * ((green - blue) / delta) + 360).truncatingRemainder(dividingBy: 360)
        } else if maxComponent == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        return (hue, saturation)
    }
}

struct CameraLavaLampView: View {
    let palette: ColorPalette
    let reduceMotion: Bool

    @State private var startDate = Date()

    var body: some View {
        if reduceMotion {
            lavaLamp(time: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                lavaLamp(time: context.date.timeIntervalSince(startDate))
            }
        }
    }

    private func lavaLamp(time: TimeInterval) -> some View {
        Rectangle()
            .fill(Color.black)
            .colorEffect(
                ShaderLibrary.dapLavaLamp(
                    .boundingRect,
                    .float(Float(time)),
                    .color(Color(rgbColor: palette.shadow)),
                    .color(Color(rgbColor: palette.dark)),
                    .color(Color(rgbColor: palette.base)),
                    .color(Color(rgbColor: palette.highlight)),
                    .color(Color(rgbColor: palette.base))
                )
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.35),
                value: palette
            )
    }
}

struct CameraPreviewView: UIViewRepresentable {
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

final class PreviewView: UIView {
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

extension Color {
    static let cameraChrome = Color.black

    init(rgbColor: RGBColor) {
        self.init(
            red: Double(rgbColor.red) / 255,
            green: Double(rgbColor.green) / 255,
            blue: Double(rgbColor.blue) / 255
        )
    }
}
