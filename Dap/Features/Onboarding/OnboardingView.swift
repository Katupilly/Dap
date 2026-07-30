import AVFoundation
import ImageIO
import SwiftUI
import UIKit

struct OnboardingView: View {
    let library: PhotoLibraryViewModel
    let onCompleted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: OnboardingPhase = .intro
    @State private var controller: CameraController?
    @State private var capturedImageData: Data?
    @State private var centralDisplayImage: UIImage?
    @State private var savedSoundID: UUID?
    @State private var isImportingCentral = false
    @State private var captureToken = UUID()
    @State private var hasAnimatedCluster = false
    @State private var clusterAssembled = false
    @State private var captureFeedback = 0
    @State private var completionFeedback = 0
    @State private var errorText = "Could not create your first Musical Photo."

    var body: some View {
        ZStack {
            OnboardingBackground(reduceMotion: reduceMotion)

            VStack(spacing: 0) {
                header

                Spacer(minLength: 22)

                mainContent
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 28)

                footer
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 34)
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase != .capture {
                stopCamera()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if phase == .capture, !isImportingCentral {
                    Task { await startCameraIfNeeded() }
                }
            case .inactive, .background:
                stopCamera()
            @unknown default:
                stopCamera()
            }
        }
        .onDisappear {
            stopCamera()
        }
        .sensoryFeedback(.selection, trigger: captureFeedback)
        .sensoryFeedback(.success, trigger: completionFeedback)
        .statusBarHidden(true)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Dap")
                .font(.custom("ZTTalk-Bold", size: 28, relativeTo: .title))
                .foregroundStyle(.white)

            if phase == .intro {
                Text("Turn a moment into music.")
                    .font(.custom("ZTTalk-Medium", size: 17, relativeTo: .body))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch phase {
        case .intro, .permission, .assembling, .ready, .failed:
            OnboardingPhotoClusterView(
                centerImage: centralDisplayImage,
                isAssembled: clusterAssembled,
                reduceMotion: reduceMotion,
                showsPulse: phase == .ready
            )
            .overlay {
                if phase == .permission || isImportingCentral {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                        .padding(18)
                        .background(.black.opacity(0.48), in: Circle())
                }
            }

        case .capture:
            captureContent
        }
    }

    private var captureContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.10))
                .aspectRatio(4.0 / 5.0, contentMode: .fit)

            if let controller {
                CameraPreviewView(controller: controller)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.42)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
            } else {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.25)
            }
        }
        .frame(maxWidth: 340)
        .accessibilityLabel("Camera preview")
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .intro:
            VStack(spacing: 12) {
                primaryButton("Create first sound", systemImage: "camera.fill") {
                    Task { await beginCameraFlow() }
                }

                secondaryButton("Use color demo") {
                    Task { await useFallbackImage() }
                }
            }

        case .permission:
            Text("Preparing camera")
                .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
                .foregroundStyle(.white.opacity(0.72))

        case .capture:
            VStack(spacing: 16) {
                Button {
                    Task { await capturePhoto() }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 88, height: 88)

                        if isImportingCentral {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Circle()
                                .fill(.white)
                                .frame(width: 74, height: 74)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(controller == nil || isImportingCentral)
                .accessibilityLabel("Take first photo")
                .accessibilityHint("Creates your first Musical Photo.")

                secondaryButton("Use color demo") {
                    Task { await useFallbackImage() }
                }
                .disabled(isImportingCentral)
            }

        case .assembling:
            Text(isImportingCentral ? "Creating sound" : "Assembling")
                .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
                .foregroundStyle(.white.opacity(0.72))

        case .ready:
            primaryButton("Start playing", systemImage: "play.fill") {
                onCompleted()
            }
            .disabled(isImportingCentral)

        case .failed:
            VStack(spacing: 12) {
                Text(errorText)
                    .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                primaryButton("Try again", systemImage: "arrow.clockwise") {
                    Task { await retryCurrentImage() }
                }
                .disabled(isImportingCentral)

                secondaryButton("Enter without photo") {
                    onCompleted()
                }
            }
        }
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
                .foregroundStyle(.black)
                .frame(maxWidth: 310)
                .frame(height: 54)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(title == "Start playing" ? "Enters Dap." : "Continues onboarding.")
    }

    private func secondaryButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
            .foregroundStyle(.white.opacity(0.82))
            .frame(height: 38)
            .buttonStyle(.plain)
    }

    @MainActor
    private func beginCameraFlow() async {
        guard phase == .intro else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            phase = .permission
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await enterCapturePhase()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            granted ? await enterCapturePhase() : await useFallbackImage()
        case .denied, .restricted:
            await useFallbackImage()
        @unknown default:
            await useFallbackImage()
        }
    }

    @MainActor
    private func enterCapturePhase() async {
        guard savedSoundID == nil, capturedImageData == nil else {
            await importCentralImageIfNeeded()
            return
        }

        withAnimation(.easeOut(duration: 0.18)) {
            phase = .capture
        }

        await startCameraIfNeeded()
    }

    @MainActor
    private func startCameraIfNeeded() async {
        guard phase == .capture else { return }

        if let controller {
            controller.start()
            return
        }

        let nextController = CameraController()
        do {
            try await nextController.configure()
            guard phase == .capture else {
                nextController.stop()
                return
            }
            controller = nextController
            nextController.start()
        } catch {
            await useFallbackImage()
        }
    }

    @MainActor
    private func capturePhoto() async {
        guard phase == .capture,
              let controller,
              !isImportingCentral,
              savedSoundID == nil else {
            return
        }

        let token = UUID()
        captureToken = token
        captureFeedback += 1
        do {
            let data = try await controller.capturePhoto(flashMode: .off)
            guard phase == .capture, captureToken == token else { return }

            stopCamera(invalidateCapture: false)
            setCentralImageData(data)
            withAnimation(.easeOut(duration: 0.18)) {
                phase = .assembling
            }
            await importCentralImageIfNeeded()
        } catch {
            guard captureToken == token else { return }
            await useFallbackImage()
        }
    }

    @MainActor
    private func useFallbackImage() async {
        guard savedSoundID == nil, !isImportingCentral else { return }

        stopCamera()
        if capturedImageData == nil {
            setCentralImageData(OnboardingTemporaryArtwork.fallbackImageData())
        }

        withAnimation(.easeOut(duration: 0.18)) {
            phase = .assembling
        }
        await importCentralImageIfNeeded()
    }

    @MainActor
    private func importCentralImageIfNeeded() async {
        guard savedSoundID == nil else {
            await animateClusterToReady()
            return
        }
        guard !isImportingCentral, let capturedImageData else { return }

        isImportingCentral = true
        defer { isImportingCentral = false }

        do {
            guard let sound = try await library.importPhotoSoundData(capturedImageData) else {
                throw OnboardingImportError.alreadyImporting
            }
            savedSoundID = sound.id
            await animateClusterToReady()
        } catch {
            errorText = error.localizedDescription
            withAnimation(.easeOut(duration: 0.16)) {
                phase = .failed
            }
        }
    }

    @MainActor
    private func retryCurrentImage() async {
        guard !isImportingCentral else { return }
        guard capturedImageData != nil else {
            await useFallbackImage()
            return
        }

        clusterAssembled = false
        hasAnimatedCluster = false
        withAnimation(.easeOut(duration: 0.16)) {
            phase = .assembling
        }
        await importCentralImageIfNeeded()
    }

    @MainActor
    private func animateClusterToReady() async {
        guard phase == .assembling else { return }

        if !hasAnimatedCluster {
            hasAnimatedCluster = true
            withAnimation(clusterAnimation) {
                clusterAssembled = true
            }
            try? await Task.sleep(nanoseconds: reduceMotion ? 180_000_000 : 920_000_000)
        }

        guard phase == .assembling, savedSoundID != nil else { return }
        completionFeedback += 1
        withAnimation(.easeOut(duration: 0.16)) {
            phase = .ready
        }
    }

    private var clusterAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.72, dampingFraction: 0.78)
    }

    @MainActor
    private func setCentralImageData(_ data: Data) {
        capturedImageData = data
        centralDisplayImage = OnboardingTemporaryArtwork.displayImage(from: data)
    }

    @MainActor
    private func stopCamera(invalidateCapture: Bool = true) {
        if invalidateCapture {
            captureToken = UUID()
        }
        controller?.stop()
        controller = nil
    }
}

private enum OnboardingPhase {
    case intro
    case permission
    case capture
    case assembling
    case ready
    case failed
}

private enum OnboardingImportError: LocalizedError {
    case alreadyImporting

    var errorDescription: String? {
        switch self {
        case .alreadyImporting:
            "Another import is already running."
        }
    }
}

private struct OnboardingBackground: View {
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.05),
                    Color(red: 0.12, green: 0.05, blue: 0.13),
                    Color(red: 0.03, green: 0.10, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            CameraLavaLampView(
                palette: RetroCoverRenderer.tonalPalette(for: .c),
                reduceMotion: reduceMotion
            )
            .opacity(0.28)
            .blur(radius: 18)
            .ignoresSafeArea()

            Color.black.opacity(0.28)
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingPhotoClusterView: View {
    let centerImage: UIImage?
    let isAssembled: Bool
    let reduceMotion: Bool
    let showsPulse: Bool

    private var items: [OnboardingClusterItem] {
        OnboardingTemporaryArtwork.clusterItems
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(proxy.size.width * 0.42, 168)
            let cardHeight = cardWidth * 1.25
            let motionScale = min(proxy.size.width / 390, 1)

            ZStack {
                ForEach(items) { item in
                    OnboardingClusterCard(
                        color: item.color,
                        image: nil,
                        label: item.label
                    )
                    .frame(width: cardWidth, height: cardHeight)
                    .scaleEffect(isAssembled ? item.finalScale : 0.82)
                    .rotationEffect(.degrees(isAssembled ? item.finalRotation : item.startRotation))
                    .offset(
                        isAssembled
                            ? item.finalOffset.scaled(by: motionScale)
                            : (reduceMotion ? item.finalOffset : item.startOffset).scaled(by: motionScale)
                    )
                    .opacity(isAssembled ? 1 : 0)
                    .zIndex(item.zIndex)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.16)
                            : .spring(response: 0.68, dampingFraction: 0.76).delay(item.delay),
                        value: isAssembled
                    )
                }

                OnboardingClusterCard(
                    color: OnboardingTemporaryArtwork.centerFallbackColor,
                    image: centerImage,
                    label: "Your first sound"
                )
                .frame(width: cardWidth * 1.1, height: cardHeight * 1.1)
                .scaleEffect(showsPulse && !reduceMotion ? 1.035 : 1)
                .shadow(color: .black.opacity(0.34), radius: 18, y: 14)
                .zIndex(10)
                .animation(.easeInOut(duration: 0.22), value: showsPulse)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 390)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Musical Photo composition")
    }
}

private struct OnboardingClusterCard: View {
    let color: Color
    let image: UIImage?
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    OnboardingTemporaryBlock()
                        .foregroundStyle(.white.opacity(0.18))
                        .padding(18)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 10)
            .accessibilityLabel(label)
    }
}

private struct OnboardingTemporaryBlock: View {
    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { column in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .opacity((row + column).isMultiple(of: 2) ? 0.96 : 0.52)
                    }
                }
            }
        }
    }
}

private struct OnboardingClusterItem: Identifiable {
    let id: Int
    let label: String
    let color: Color
    let startOffset: CGSize
    let finalOffset: CGSize
    let startRotation: Double
    let finalRotation: Double
    let finalScale: CGFloat
    let delay: TimeInterval
    let zIndex: Double
}

private enum OnboardingTemporaryArtwork {
    static let centerFallbackColor = Color(red: 0.94, green: 0.20, blue: 0.32)

    static let clusterItems: [OnboardingClusterItem] = [
        OnboardingClusterItem(
            id: 0,
            label: "Visual layer one",
            color: Color(red: 0.12, green: 0.72, blue: 0.86),
            startOffset: CGSize(width: -190, height: -230),
            finalOffset: CGSize(width: -84, height: -96),
            startRotation: -18,
            finalRotation: -9,
            finalScale: 0.72,
            delay: 0.02,
            zIndex: 3
        ),
        OnboardingClusterItem(
            id: 1,
            label: "Visual layer two",
            color: Color(red: 0.98, green: 0.72, blue: 0.18),
            startOffset: CGSize(width: 196, height: -218),
            finalOffset: CGSize(width: 82, height: -88),
            startRotation: 16,
            finalRotation: 8,
            finalScale: 0.70,
            delay: 0.09,
            zIndex: 2
        ),
        OnboardingClusterItem(
            id: 2,
            label: "Visual layer three",
            color: Color(red: 0.44, green: 0.34, blue: 0.96),
            startOffset: CGSize(width: -202, height: 230),
            finalOffset: CGSize(width: -88, height: 94),
            startRotation: 15,
            finalRotation: 7,
            finalScale: 0.71,
            delay: 0.15,
            zIndex: 4
        ),
        OnboardingClusterItem(
            id: 3,
            label: "Visual layer four",
            color: Color(red: 0.36, green: 0.88, blue: 0.38),
            startOffset: CGSize(width: 204, height: 224),
            finalOffset: CGSize(width: 88, height: 98),
            startRotation: -15,
            finalRotation: -8,
            finalScale: 0.69,
            delay: 0.21,
            zIndex: 1
        )
    ]

    static func fallbackImageData() -> Data {
        let size = CGSize(width: 900, height: 1125)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(red: 0.94, green: 0.20, blue: 0.32, alpha: 1).setFill()
            context.cgContext.fill(rect)

            let blocks: [(UIColor, CGRect)] = [
                (
                    UIColor(red: 0.12, green: 0.72, blue: 0.86, alpha: 1),
                    CGRect(x: 82, y: 96, width: 328, height: 318)
                ),
                (
                    UIColor(red: 0.98, green: 0.72, blue: 0.18, alpha: 1),
                    CGRect(x: 476, y: 150, width: 260, height: 292)
                ),
                (
                    UIColor(red: 0.44, green: 0.34, blue: 0.96, alpha: 1),
                    CGRect(x: 146, y: 548, width: 286, height: 344)
                ),
                (
                    UIColor(red: 0.36, green: 0.88, blue: 0.38, alpha: 1),
                    CGRect(x: 508, y: 604, width: 264, height: 312)
                )
            ]

            for (color, blockRect) in blocks {
                color.setFill()
                UIBezierPath(roundedRect: blockRect, cornerRadius: 18).fill()
            }
        }
    }

    static func displayImage(from data: Data) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}

private extension CGSize {
    func scaled(by scale: CGFloat) -> CGSize {
        CGSize(width: width * scale, height: height * scale)
    }
}
