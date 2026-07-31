import AVFoundation
import CoreHaptics
import ImageIO
import OSLog
import PhotosUI
import SwiftUI
import UIKit

struct OnboardingView: View {
    let library: PhotoLibraryViewModel
    let onCompleted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: OnboardingPhase = .splash
    @State private var controller: CameraController?
    @State private var input: OnboardingInput?
    @State private var centralDisplayImage: UIImage?
    @State private var capturedPreviewImage: UIImage?
    @State private var preparationReveal = false
    @State private var assemblyTask: Task<Void, Never>?
    @State private var assemblyToken = UUID()
    @State private var captureToken = UUID()
    @State private var captureTask: Task<Void, Never>?
    @State private var preparationTask: Task<Void, Never>?
    @State private var preparationToken = UUID()
    @State private var preparedPhoto: PreparedPhotoInput?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isCapturing = false
    @State private var isPreparingPhoto = false
    @State private var isSwitchingCamera = false
    @State private var isRequestingPermission = false
    @State private var isPushingIntro = false
    @State private var hasAnimatedCluster = false
    @State private var clusterAssembled = false
    @State private var assemblyMessage = "Lendo as cores da sua foto…"
    @State private var captureFeedback = 0
    @State private var completionFeedback = 0
    @State private var splashRiseFeedback = 0
    @State private var splashRotationFeedback = 0
    @State private var splashExitFeedback = 0
    @State private var splashHapticPlayer = SplashHapticPlayer()
    @State private var primaryActionFeedback = 0
    @State private var secondaryActionFeedback = 0
    @State private var permissionIssue: OnboardingPermissionIssue = .denied
    @State private var failure: OnboardingFailure?

    #if DEBUG
    private static let performanceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Dap",
        category: "Performance"
    )
    #endif

    var body: some View {
        ZStack {
            Color.onboardingCanvas
                .ignoresSafeArea()

            Group {
                if phase.usesLightLayout {
                    lightContent
                } else {
                    darkContent
                }
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase != .capture {
                stopCamera()
            }
            if newPhase != .splash {
                splashHapticPlayer.stop()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if phase == .capture, !isCapturing {
                    Task { await startCameraIfNeeded() }
                }
                if phase == .permissionDenied {
                    recheckCameraPermission()
                }
            case .inactive, .background:
                stopCamera()
            @unknown default:
                stopCamera()
            }
        }
        .onDisappear {
            captureTask?.cancel()
            captureTask = nil
            preparationTask?.cancel()
            preparationTask = nil
            assemblyTask?.cancel()
            assemblyTask = nil
            library.stopTransientPlayback()
            stopCamera()
            splashHapticPlayer.stop()
        }
        .sensoryFeedback(.selection, trigger: captureFeedback)
        .sensoryFeedback(.success, trigger: completionFeedback)
        .sensoryFeedback(
            .impact(weight: .heavy, intensity: 1.0),
            trigger: splashRiseFeedback
        )
        .sensoryFeedback(
            .impact(flexibility: .rigid, intensity: 1.0),
            trigger: splashRotationFeedback
        )
        .sensoryFeedback(
            .impact(weight: .medium, intensity: 0.8),
            trigger: splashExitFeedback
        )
        .sensoryFeedback(
            .impact(weight: .medium, intensity: 0.8),
            trigger: primaryActionFeedback
        )
        .sensoryFeedback(
            .impact(weight: .light, intensity: 0.65),
            trigger: secondaryActionFeedback
        )
        .statusBarHidden(!phase.usesLightLayout)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            captureTask?.cancel()
            captureTask = Task { await importPhoto(item) }
        }
        .task(id: phase) {
            await advanceSplashIfNeeded()
        }
    }

    private var darkContent: some View {
        ZStack {
            if phase == .capture || phase == .preparingReview {
                Color.onboardingInkwell
                    .ignoresSafeArea()
            } else {
                OnboardingBackground(reduceMotion: reduceMotion)
            }

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
    }

    @ViewBuilder
    private var lightContent: some View {
        switch phase {
        case .splash:
            OnboardingSplashMotionView(reduceMotion: reduceMotion)
                .onAppear {
                    if !reduceMotion {
                        _ = splashHapticPlayer.prepare()
                    }
                }
        case .photoIntoMusic, .permissionPrimer:
            OnboardingIntroFlowView(
                phase: phase,
                reduceMotion: reduceMotion,
                isCreateDisabled: isPushingIntro,
                isAllowDisabled: isRequestingPermission,
                onCreate: {
                    guard phase == .photoIntoMusic, !isPushingIntro else { return }
                    isPushingIntro = true
                    primaryActionFeedback += 1
                    withAnimation(
                        reduceMotion
                            ? .easeOut(duration: 0.16)
                            : .snappy(duration: 0.42, extraBounce: 0)
                    ) {
                        phase = .permissionPrimer
                    }
                },
                onAllow: {
                    guard !isRequestingPermission else { return }
                    isRequestingPermission = true
                    primaryActionFeedback += 1
                    Task { await requestCameraAccess() }
                },
                onDemo: {
                    guard !isRequestingPermission else { return }
                    secondaryActionFeedback += 1
                    startPhotoPreparation(
                        source: .demo(OnboardingTemporaryArtwork.fallbackImageData())
                    )
                }
            )
        case .capture, .preparingReview, .review, .assembling, .ready, .permissionDenied, .technicalError:
            EmptyView()
        }
    }

    @MainActor
    private func advanceSplashIfNeeded() async {
        guard isCurrentSplashTask() else { return }

        if reduceMotion {
            do {
                try await Task.sleep(nanoseconds: OnboardingSplashTiming.reduceMotionAdvanceNanoseconds)
            } catch {
                return
            }

            guard isCurrentSplashTask() else { return }
            setPhaseWithoutAnimation(.photoIntoMusic)
            return
        }

        let usesCoreHaptics = splashHapticPlayer.startPattern()

        do {
            try await Task.sleep(nanoseconds: OnboardingSplashTiming.riseStartNanoseconds)
        } catch {
            return
        }

        guard isCurrentSplashTask() else { return }
        if !usesCoreHaptics {
            splashRiseFeedback += 1
        }

        do {
            try await Task.sleep(
                nanoseconds: OnboardingSplashTiming.rotationStartNanoseconds
                    - OnboardingSplashTiming.riseStartNanoseconds
            )
        } catch {
            return
        }

        guard isCurrentSplashTask() else { return }
        if !usesCoreHaptics {
            splashRotationFeedback += 1
        }

        do {
            try await Task.sleep(
                nanoseconds: OnboardingSplashTiming.exitStartNanoseconds
                    - OnboardingSplashTiming.rotationStartNanoseconds
            )
        } catch {
            return
        }

        guard isCurrentSplashTask() else { return }
        if !usesCoreHaptics {
            splashExitFeedback += 1
        }

        do {
            try await Task.sleep(
                nanoseconds: OnboardingSplashTiming.durationNanoseconds
                    - OnboardingSplashTiming.exitStartNanoseconds
            )
        } catch {
            return
        }

        guard isCurrentSplashTask() else { return }
        setPhaseWithoutAnimation(.photoIntoMusic)
    }

    @MainActor
    private func setPhaseWithoutAnimation(_ nextPhase: OnboardingPhase) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            phase = nextPhase
        }
    }

    @MainActor
    private func isCurrentSplashTask() -> Bool {
        !Task.isCancelled && phase == .splash
    }

    @MainActor
    private func isCurrentCapture(_ token: UUID) -> Bool {
        !Task.isCancelled && phase == .capture && captureToken == token
    }

    private var header: some View {
        Text("Dap")
            .font(.custom("ZTTalk-Bold", size: 28, relativeTo: .title))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch phase {
        case .splash, .photoIntoMusic:
            EmptyView()

        case .permissionPrimer:
            EmptyView()

        case .assembling, .ready:
            OnboardingPhotoClusterView(
                centerImage: centralDisplayImage,
                isAssembled: clusterAssembled,
                reduceMotion: reduceMotion,
                showsPulse: phase == .ready
            )

        case .capture:
            captureContent

        case .preparingReview:
            photoPreparationContent

        case .review:
            reviewContent

        case .permissionDenied:
            permissionDeniedContent

        case .technicalError:
            technicalErrorContent
        }
    }

    private var captureContent: some View {
        VStack(spacing: 10) {
            Text("Enquadre algo com cor e contraste.")
                .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
                .foregroundStyle(.white.opacity(0.76))

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
        }
        .accessibilityLabel("Pré-visualização da câmera")
    }

    private var photoPreparationContent: some View {
        VStack(spacing: 12) {
            if let capturedPreviewImage {
                Image(uiImage: capturedPreviewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 340)
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .saturation(preparationReveal ? 1 : 0.86)
                    .brightness(preparationReveal ? 0.02 : -0.02)
                    .contrast(preparationReveal ? 1.02 : 0.98)
                    .animation(.easeInOut(duration: 0.5), value: preparationReveal)
                    .transition(.opacity)
                    .accessibilityLabel("Foto selecionada")
            }

            Text("Revelando sua foto…")
                .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
                .foregroundStyle(.white.opacity(0.76))
        }
    }

    private var reviewContent: some View {
        VStack(spacing: 14) {
            Text("Veja sua foto")
                .font(.custom("ZTTalk-Bold", size: 25, relativeTo: .title2))
                .foregroundStyle(.white)

            if let centralDisplayImage {
                Image(uiImage: centralDisplayImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 340)
                    .aspectRatio(4.0 / 5.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.opacity)
                    .accessibilityLabel("Foto capturada")
            }
        }
    }

    private var permissionDeniedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: permissionIssue == .restricted ? "lock.fill" : "camera.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)

            Text(permissionIssue.title)
                .font(.custom("ZTTalk-Bold", size: 25, relativeTo: .title2))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(permissionIssue.message)
                .font(.custom("ZTTalk-Medium", size: 16, relativeTo: .body))
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
    }

    private var technicalErrorContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)

            Text("Algo deu errado")
                .font(.custom("ZTTalk-Bold", size: 25, relativeTo: .title2))
                .foregroundStyle(.white)

            Text(failure?.message ?? "Não foi possível concluir sua criação.")
                .font(.custom("ZTTalk-Medium", size: 16, relativeTo: .body))
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .permissionPrimer:
            EmptyView()

        case .splash, .photoIntoMusic:
            EmptyView()

        case .capture:
            VStack(spacing: 16) {
                HStack {
                    Color.clear
                        .frame(width: 57, height: 57)

                    Spacer()

                    Button {
                        captureTask = Task { await capturePhoto() }
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 4)
                                .frame(width: 88, height: 88)

                            Circle()
                                .fill(.white)
                                .frame(width: 74, height: 74)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(controller == nil || isCapturing || isPreparingPhoto)
                    .accessibilityLabel("Tirar foto")
                    .accessibilityHint("Captura a foto que será transformada em música.")

                    Spacer()

                    CaptureFlipCameraButton(
                        isEnabled: controller != nil
                            && !isCapturing
                            && !isPreparingPhoto
                            && !isSwitchingCamera
                    ) {
                        captureTask = Task { await switchCamera() }
                    }
                }
                .padding(.horizontal, 16)

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Text("Escolher da biblioteca")
                }
                .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
                .foregroundStyle(.white.opacity(0.82))
                .frame(height: 38)
                .buttonStyle(.plain)
                .disabled(isCapturing || isPreparingPhoto || isSwitchingCamera)

                secondaryButton("Usar uma imagem de demonstração") {
                    startPhotoPreparation(
                        source: .demo(OnboardingTemporaryArtwork.fallbackImageData())
                    )
                }
                .disabled(isCapturing || isPreparingPhoto || isSwitchingCamera)
            }

        case .preparingReview:
            Text("Revelando sua foto…")
                .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
                .foregroundStyle(.white.opacity(0.76))

        case .review:
            VStack(spacing: 12) {
                primaryButton("Usar essa foto", systemImage: "checkmark") {
                    confirmPhoto()
                }

                secondaryButton("Tirar outra") {
                    Task { await retakePhoto() }
                }
            }

        case .assembling:
            VStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text(assemblyMessage)
            }
            .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
            .foregroundStyle(.white.opacity(0.72))

        case .ready:
            VStack(spacing: 12) {
                Text(input == .demo
                     ? "Essa é uma música de demonstração criada pelo Dap."
                     : "Essa é a música da sua foto. Cada nova imagem cria um som diferente.")
                    .font(.custom("ZTTalk-Medium", size: 15, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                primaryButton("Explorar o Dap", systemImage: "arrow.right") {
                    library.stopTransientPlayback()
                    onCompleted()
                }
            }

        case .permissionDenied:
            VStack(spacing: 12) {
                if permissionIssue == .denied {
                    primaryButton("Abrir Ajustes", systemImage: "gear") {
                        openSettings()
                    }
                } else {
                    primaryButton("Continuar com demonstração", systemImage: "play.fill") {
                        startPhotoPreparation(
                            source: .demo(OnboardingTemporaryArtwork.fallbackImageData())
                        )
                    }
                }

                secondaryButton(permissionIssue == .denied ? "Continuar com demonstração" : "Verificar novamente") {
                    if permissionIssue == .denied {
                        startPhotoPreparation(
                            source: .demo(OnboardingTemporaryArtwork.fallbackImageData())
                        )
                    } else {
                        recheckCameraPermission()
                    }
                }
            }

        case .technicalError:
            VStack(spacing: 12) {
                primaryButton("Tentar novamente", systemImage: "arrow.clockwise") {
                    retryAfterFailure()
                }

                secondaryButton("Continuar com demonstração") {
                    startPhotoPreparation(
                        source: .demo(OnboardingTemporaryArtwork.fallbackImageData())
                    )
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
        .accessibilityHint(title == "Explorar o Dap" ? "Entra no Dap." : "Continua o onboarding.")
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
    private func requestCameraAccess() async {
        guard phase == .permissionPrimer else {
            isRequestingPermission = false
            return
        }
        defer { isRequestingPermission = false }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await enterCapturePhase()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                await enterCapturePhase()
            } else {
                showPermissionDenied(.denied)
            }
        case .denied:
            showPermissionDenied(.denied)
        case .restricted:
            showPermissionDenied(.restricted)
        @unknown default:
            failure = .permissionCheckFailed
            phase = .technicalError
        }
    }

    @MainActor
    private func enterCapturePhase() async {
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
            failure = .captureFailed
            withAnimation(.easeOut(duration: 0.16)) {
                phase = .technicalError
            }
        }
    }

    @MainActor
    private func importPhoto(_ item: PhotosPickerItem) async {
        selectedPhoto = nil
        guard phase == .capture,
              !isCapturing,
              !isSwitchingCamera else {
            return
        }

        let token = UUID()
        captureToken = token
        isPreparingPhoto = true
        defer { isPreparingPhoto = false }
        let flowClock = ContinuousClock()
        let flowStart = flowClock.now

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PhotoMusicPipelineError.decodeFailed
            }
            guard !Task.isCancelled, phase == .capture, captureToken == token else { return }
            startPhotoPreparation(source: .library(data), startedAt: flowStart)
        } catch is CancellationError {
            return
        } catch {
            guard captureToken == token else { return }
            failure = .captureFailed
            withAnimation(.easeOut(duration: 0.16)) {
                phase = .technicalError
            }
        }
    }

    @MainActor
    private func capturePhoto() async {
        guard phase == .capture,
              let controller,
              !isCapturing,
              !isPreparingPhoto,
              !isSwitchingCamera else {
            return
        }

        let token = UUID()
        captureToken = token
        isPreparingPhoto = true
        defer { isPreparingPhoto = false }
        let flowClock = ContinuousClock()
        let flowStart = flowClock.now
        isCapturing = true
        captureFeedback += 1
        defer { isCapturing = false }

        do {
            let data = try await controller.capturePhoto(flashMode: .off)
            guard isCurrentCapture(token) else { return }

            stopCamera(invalidateCapture: false)
            startPhotoPreparation(source: .camera(data), startedAt: flowStart)
        } catch is CancellationError {
            return
        } catch {
            guard captureToken == token else { return }
            failure = .captureFailed
            withAnimation(.easeOut(duration: 0.16)) {
                phase = .technicalError
            }
        }
    }

    @MainActor
    private func startPhotoPreparation(
        source: OnboardingPhotoSource,
        startedAt: ContinuousClock.Instant? = nil
    ) {
        preparationTask?.cancel()
        let token = UUID()
        preparationToken = token
        preparedPhoto = nil
        input = source.input
        centralDisplayImage = nil
        capturedPreviewImage = UIImage(data: source.data)
        preparationReveal = false
        stopCamera()

        withAnimation(.easeOut(duration: 0.16)) {
            phase = .preparingReview
        }
        preparationReveal = true

        let clock = ContinuousClock()
        let preparationStart = startedAt ?? clock.now
        preparationTask = Task { @MainActor [source, token] in
            do {
                let prepared = try await PhotoMusicPipeline.prepare(imageData: source.data)
                guard isCurrentPreparation(token) else { return }

                preparedPhoto = prepared
                centralDisplayImage = OnboardingTemporaryArtwork.displayImage(
                    from: prepared.processedPreviewData
                )
                #if DEBUG
                Self.performanceLogger.debug(
                    "onboarding photo to review: \(String(describing: preparationStart.duration(to: clock.now)), privacy: .public)"
                )
                #endif

                if source.isDemo {
                    beginAssembly(source.input, preparedPhoto: prepared)
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        phase = .review
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentPreparation(token) else { return }
                failure = source.isDemo ? .generationFailed : .captureFailed
                withAnimation(.easeOut(duration: 0.16)) {
                    phase = .technicalError
                }
            }
        }
    }

    @MainActor
    private func switchCamera() async {
        guard phase == .capture,
              let controller,
              !isCapturing,
              !isPreparingPhoto,
              !isSwitchingCamera else {
            return
        }

        isSwitchingCamera = true
        defer { isSwitchingCamera = false }

        do {
            try await controller.switchCamera()
        } catch {
            failure = .captureFailed
            withAnimation(.easeOut(duration: 0.16)) {
                phase = .technicalError
            }
        }
    }

    @MainActor
    private func confirmPhoto() {
        guard phase == .review, case .captured = input, let input else { return }
        beginAssembly(input, preparedPhoto: preparedPhoto)
    }

    @MainActor
    private func retakePhoto() async {
        guard phase == .review else { return }

        assemblyTask?.cancel()
        captureTask?.cancel()
        preparationTask?.cancel()
        preparationToken = UUID()
        input = nil
        centralDisplayImage = nil
        capturedPreviewImage = nil
        preparationReveal = false
        preparedPhoto = nil
        selectedPhoto = nil
        clusterAssembled = false
        hasAnimatedCluster = false
        withAnimation(.easeOut(duration: 0.18)) {
            phase = .capture
        }
        await startCameraIfNeeded()
    }

    @MainActor
    private func beginAssembly(
        _ input: OnboardingInput,
        preparedPhoto: PreparedPhotoInput? = nil
    ) {
        guard phase != .assembling, phase != .ready else { return }

        assemblyTask?.cancel()
        let token = UUID()
        assemblyToken = token
        let resolvedPreparedPhoto = preparedPhoto ?? self.preparedPhoto
        self.input = input
        failure = nil
        clusterAssembled = false
        hasAnimatedCluster = false
        self.preparedPhoto = resolvedPreparedPhoto
        capturedPreviewImage = nil
        assemblyMessage = "Lendo as cores da sua foto…"

        if case .demo = input, resolvedPreparedPhoto == nil {
            centralDisplayImage = nil
        }
        stopCamera()

        withAnimation(.easeOut(duration: 0.18)) {
            phase = .assembling
        }

        assemblyTask = Task { @MainActor [input, token, resolvedPreparedPhoto] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard isCurrentAssembly(token) else { return }
                assemblyMessage = "Transformando em melodia…"

                let sound: PhotoSound
                switch input {
                case .captured(let data):
                    let imported: PhotoSound?
                    if let resolvedPreparedPhoto {
                        imported = try await library.importPreparedPhoto(resolvedPreparedPhoto)
                    } else {
                        imported = try await library.importPhotoSoundData(data)
                    }
                    guard let imported else {
                        throw OnboardingImportError.alreadyImporting
                    }
                    sound = imported
                case .demo:
                    let processed: ProcessedPhotoSound
                    if let resolvedPreparedPhoto {
                        processed = try await PhotoMusicPipeline.process(prepared: resolvedPreparedPhoto)
                    } else {
                        processed = try await PhotoMusicPipeline.process(
                            imageData: OnboardingTemporaryArtwork.fallbackImageData()
                        )
                    }
                    guard isCurrentAssembly(token) else { return }
                    centralDisplayImage = OnboardingTemporaryArtwork.displayImage(from: processed.coverData)
                    sound = processed.sound
                }

                guard isCurrentAssembly(token) else { return }
                library.playTransientSequence(sound.sequence)
                withAnimation(clusterAnimation) {
                    hasAnimatedCluster = true
                    clusterAssembled = true
                }
                self.preparedPhoto = nil
                try await Task.sleep(nanoseconds: reduceMotion ? 180_000_000 : 920_000_000)
                guard isCurrentAssembly(token) else { return }

                completionFeedback += 1
                withAnimation(.easeOut(duration: 0.16)) {
                    phase = .ready
                }
                assemblyTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentAssembly(token) else { return }
                failure = input == .demo ? .generationFailed : .importFailed
                withAnimation(.easeOut(duration: 0.16)) {
                    phase = .technicalError
                }
                assemblyTask = nil
            }
        }
    }

    private var clusterAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.72, dampingFraction: 0.78)
    }

    @MainActor
    private func showPermissionDenied(_ issue: OnboardingPermissionIssue) {
        permissionIssue = issue
        withAnimation(.easeOut(duration: 0.16)) {
            phase = .permissionDenied
        }
    }

    @MainActor
    private func recheckCameraPermission() {
        guard phase == .permissionDenied else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            Task { await enterCapturePhase() }
        case .denied:
            permissionIssue = .denied
        case .restricted:
            permissionIssue = .restricted
        case .notDetermined:
            withAnimation(.easeOut(duration: 0.16)) {
                phase = .permissionPrimer
            }
        @unknown default:
            failure = .permissionCheckFailed
            phase = .technicalError
        }
    }

    @MainActor
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    @MainActor
    private func retryAfterFailure() {
        switch failure {
        case .captureFailed:
            Task { await enterCapturePhase() }
        case .importFailed:
            if let input {
                beginAssembly(input, preparedPhoto: preparedPhoto)
            } else {
                phase = .permissionPrimer
            }
        case .generationFailed:
            if let preparedPhoto {
                beginAssembly(.demo, preparedPhoto: preparedPhoto)
            } else {
                startPhotoPreparation(
                    source: .demo(OnboardingTemporaryArtwork.fallbackImageData())
                )
            }
        case .permissionCheckFailed, nil:
            phase = .permissionPrimer
        }
    }

    @MainActor
    private func isCurrentAssembly(_ token: UUID) -> Bool {
        !Task.isCancelled && phase == .assembling && assemblyToken == token
    }

    @MainActor
    private func isCurrentPreparation(_ token: UUID) -> Bool {
        !Task.isCancelled && phase == .preparingReview && preparationToken == token
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

@MainActor
private final class SplashHapticPlayer {
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?

    func startPattern() -> Bool {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        guard prepare() else { return false }

        let events = [
            transient(intensity: 0.48, sharpness: 0.38, at: 0.404),
            transient(intensity: 0.58, sharpness: 0.44, at: 0.800),
            transient(intensity: 0.68, sharpness: 0.50, at: 1.200),
            transient(intensity: 0.78, sharpness: 0.58, at: 1.600),
            transient(intensity: 0.88, sharpness: 0.68, at: 1.960),
            transient(intensity: 1.00, sharpness: 1.00, at: 2.22724),
            transient(intensity: 0.72, sharpness: 0.90, at: 2.300),
            transient(intensity: 0.65, sharpness: 0.48, at: 3.004)
        ]

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine?.makePlayer(with: pattern)
            guard let player else { return false }
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
            return true
        } catch {
            stop()
            return false
        }
    }

    func prepare() -> Bool {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return false }
        guard engine == nil else { return true }

        do {
            let engine = try CHHapticEngine()
            engine.resetHandler = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleEngineReset()
                }
            }
            try engine.start()
            self.engine = engine
            return true
        } catch {
            self.engine = nil
            return false
        }
    }

    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine?.stop(completionHandler: nil)
        engine = nil
    }

    private func transient(intensity: Float, sharpness: Float, at time: TimeInterval) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time
        )
    }

    private func handleEngineReset() {
        player = nil
        engine = nil
    }
}

private enum OnboardingSplashTiming {
    static let duration: TimeInterval = 4
    static let durationNanoseconds: UInt64 = 4_000_000_000
    static let riseStartNanoseconds: UInt64 = 404_000_000
    static let rotationStartNanoseconds: UInt64 = 2_227_240_000
    static let exitStartNanoseconds: UInt64 = 3_004_000_000
    static let reduceMotionAdvanceNanoseconds: UInt64 = 180_000_000
}

private enum OnboardingPhase: Equatable {
    case splash
    case photoIntoMusic
    case permissionPrimer
    case capture
    case preparingReview
    case review
    case assembling
    case ready
    case permissionDenied
    case technicalError

    var usesLightLayout: Bool {
        switch self {
        case .splash, .photoIntoMusic, .permissionPrimer:
            true
        case .capture, .preparingReview, .review, .assembling, .ready, .permissionDenied, .technicalError:
            false
        }
    }
}

private enum OnboardingPhotoSource: Sendable {
    case camera(Data)
    case library(Data)
    case demo(Data)

    var data: Data {
        switch self {
        case .camera(let data), .library(let data), .demo(let data):
            data
        }
    }

    var input: OnboardingInput {
        switch self {
        case .demo:
            .demo
        case .camera(let data), .library(let data):
            .captured(data)
        }
    }

    var isDemo: Bool {
        if case .demo = self { true } else { false }
    }
}

private enum OnboardingInput: Equatable {
    case captured(Data)
    case demo
}

private enum OnboardingPermissionIssue: Equatable {
    case denied
    case restricted

    var title: String {
        switch self {
        case .denied: "Câmera desativada"
        case .restricted: "Câmera indisponível"
        }
    }

    var message: String {
        switch self {
        case .denied:
            "Você pode ativar o acesso à câmera nos Ajustes do sistema ou continuar com uma demonstração."
        case .restricted:
            "O acesso à câmera está bloqueado por uma restrição do sistema. Continue com uma demonstração para conhecer o Dap."
        }
    }
}

private enum OnboardingFailure {
    case permissionCheckFailed
    case captureFailed
    case importFailed
    case generationFailed

    var message: String {
        switch self {
        case .permissionCheckFailed:
            "Não foi possível verificar o acesso à câmera."
        case .captureFailed:
            "Não foi possível capturar a foto. Tente novamente ou use uma demonstração."
        case .importFailed:
            "Não foi possível salvar essa foto. Tente novamente ou use uma demonstração."
        case .generationFailed:
            "Não foi possível transformar a demonstração em música. Tente novamente."
        }
    }
}

private enum OnboardingImportError: Error {
    case alreadyImporting
}

private extension Color {
    static let onboardingCanvas = Color(red: 251 / 255, green: 251 / 255, blue: 251 / 255)
    static let onboardingInkwell = Color(red: 26 / 255, green: 26 / 255, blue: 30 / 255)
    static let onboardingInactive = Color(red: 174 / 255, green: 174 / 255, blue: 178 / 255)
}

private struct OnboardingCanvasMetrics {
    let scale: CGFloat
    let origin: CGPoint
    let safeAreaTop: CGFloat

    func point(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }

    func length(_ value: CGFloat) -> CGFloat {
        value * scale
    }
}

private struct OnboardingReferenceCanvas<Content: View>: View {
    let content: (OnboardingCanvasMetrics) -> Content

    init(@ViewBuilder content: @escaping (OnboardingCanvasMetrics) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 393, proxy.size.height / 852)
            let origin = CGPoint(
                x: (proxy.size.width - 393 * scale) / 2,
                y: (proxy.size.height - 852 * scale) / 2
            )

            content(
                OnboardingCanvasMetrics(
                    scale: scale,
                    origin: origin,
                    safeAreaTop: proxy.safeAreaInsets.top
                )
            )
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingLightLogo: View {
    let scale: CGFloat

    init(scale: CGFloat = 1) {
        self.scale = scale
    }

    var body: some View {
        Text("dap")
            .font(.custom("ZTTalk-Bold", size: 30.436 * scale, relativeTo: .title))
            .foregroundStyle(Color.onboardingInkwell)
            .fixedSize()
            .accessibilityLabel("Dap")
    }
}

private let onboardingSplashScaleNormalization = 567.157 / 30.436
private let onboardingHeaderLogoScale = 0.05 * onboardingSplashScaleNormalization

private struct OnboardingStepIndicator: View {
    let firstColor: Color
    let secondColor: Color
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 4 * scale) {
            Capsule()
                .fill(firstColor)
                .frame(width: 40.27 * scale, height: 2.822 * scale)

            Capsule()
                .fill(secondColor)
                .frame(width: 40.27 * scale, height: 2.822 * scale)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding progress, two steps")
    }
}

private struct OnboardingDarkPillButton: View {
    let title: String
    let size: CGSize
    let font: Font
    let tracking: CGFloat
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .background(Color.onboardingInkwell, in: Capsule())
            .buttonStyle(.plain)
    }
}

private struct OnboardingMotionKeyframe {
    enum Easing {
        case linear
        case cubic(Double, Double, Double, Double)
    }

    let progress: Double
    let value: Double
    let easing: Easing

    init(_ progress: Double, _ value: Double, easing: Easing = .linear) {
        self.progress = progress
        self.value = value
        self.easing = easing
    }
}

private func onboardingMotionValue(
    at progress: Double,
    keyframes: [OnboardingMotionKeyframe]
) -> Double {
    guard let first = keyframes.first else { return 0 }
    guard progress > first.progress else { return first.value }

    for index in 1 ..< keyframes.count {
        let next = keyframes[index]
        guard progress <= next.progress else { continue }
        let previous = keyframes[index - 1]
        let duration = next.progress - previous.progress
        guard duration > 0 else { return next.value }
        let localProgress = (progress - previous.progress) / duration
        let easedProgress: Double
        switch next.easing {
        case .linear:
            easedProgress = localProgress
        case let .cubic(x1, y1, x2, y2):
            easedProgress = onboardingCubicBezier(localProgress, x1: x1, y1: y1, x2: x2, y2: y2)
        }
        return previous.value + (next.value - previous.value) * easedProgress
    }

    return keyframes.last?.value ?? first.value
}

private func onboardingCubicBezier(
    _ progress: Double,
    x1: Double,
    y1: Double,
    x2: Double,
    y2: Double
) -> Double {
    let target = min(max(progress, 0), 1)
    var lower = 0.0
    var upper = 1.0

    for _ in 0 ..< 14 {
        let guess = (lower + upper) / 2
        if onboardingCubicComponent(guess, first: x1, second: x2) < target {
            lower = guess
        } else {
            upper = guess
        }
    }

    return onboardingCubicComponent((lower + upper) / 2, first: y1, second: y2)
}

private func onboardingCubicComponent(_ value: Double, first: Double, second: Double) -> Double {
    let inverse = 1 - value
    return 3 * inverse * inverse * value * first
        + 3 * inverse * value * value * second
        + value * value * value
}

private func onboardingPermissionBounce(_ progress: Double) -> Double {
    let values = [
        0.0, 0.0188, 0.0679, 0.1374, 0.2195, 0.308, 0.3978, 0.4856, 0.5686,
        0.6452, 0.7142, 0.7753, 0.8283, 0.8735, 0.9113, 0.9423, 0.9671, 0.9866,
        1.0014, 1.0123, 1.0198, 1.0247, 1.0274, 1.0283, 1.0281, 1.0268, 1.025,
        1.0227, 1.0202, 1.0177, 1.0152, 1.0128, 1.0106, 1.0085, 1.0068, 1.0052,
        1.0039, 1.0028, 1.0018, 1.0011, 1.0005, 1.0, 0.9997, 0.9995, 0.9993,
        0.9992, 0.9992, 0.9992, 0.9993, 0.9993
    ]
    let clampedProgress = min(max(progress, 0), 1)
    let scaledProgress = clampedProgress * Double(values.count - 1)
    let index = min(Int(scaledProgress), values.count - 2)
    let remainder = scaledProgress - Double(index)
    return values[index] + (values[index + 1] - values[index]) * remainder
}

private struct OnboardingRGB {
    let red: Double
    let green: Double
    let blue: Double
}

private let onboardingInkwellRGB = OnboardingRGB(red: 26 / 255, green: 26 / 255, blue: 30 / 255)
private let onboardingInactiveRGB = OnboardingRGB(red: 174 / 255, green: 174 / 255, blue: 178 / 255)

private func onboardingBlendedColor(from: OnboardingRGB, to: OnboardingRGB, progress: Double) -> Color {
    let clampedProgress = min(max(progress, 0), 1)
    return Color(
        red: from.red + (to.red - from.red) * clampedProgress,
        green: from.green + (to.green - from.green) * clampedProgress,
        blue: from.blue + (to.blue - from.blue) * clampedProgress
    )
}

private struct OnboardingSplashMotionView: View {
    let reduceMotion: Bool

    @State private var startDate = Date()

    var body: some View {
        if reduceMotion {
            content(progress: 1, reduceMotion: true)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                content(
                    progress: min(
                        max(
                            context.date.timeIntervalSince(startDate) / OnboardingSplashTiming.duration,
                            0
                        ),
                        1
                    ),
                    reduceMotion: false
                )
            }
        }
    }

    private func content(progress: Double, reduceMotion: Bool) -> some View {
        let timelineProgress = reduceMotion ? 1 : progress
        let scale = reduceMotion ? 1 : onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 6.37 * onboardingSplashScaleNormalization),
                .init(0.101, 6.37 * onboardingSplashScaleNormalization),
                .init(0.55681, 1 * onboardingSplashScaleNormalization, easing: .cubic(1, 0.006, 0, 0.993)),
                .init(0.751, 0.15 * onboardingSplashScaleNormalization, easing: .cubic(1, 0.005, 0, 0.995)),
                .init(0.90225, 0.05 * onboardingSplashScaleNormalization, easing: .cubic(1, 0.007, 0, 0.991)),
                .init(1, 0.05 * onboardingSplashScaleNormalization)
            ]
        )
        let translationY = reduceMotion ? 0 : onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, -1802.001),
                .init(0.101, -1802.001),
                .init(0.55681, 30.998, easing: .cubic(1, -0.007, 0, 0.977)),
                .init(0.751, 30.998),
                .init(0.90225, -313.303, easing: .cubic(1, 0.01, 0, 1.002)),
                .init(1, -313.303)
            ]
        )
        let translationX = reduceMotion ? 0 : onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.101, 0),
                .init(0.55681, -3.719, easing: .cubic(1, -0.007, 0, 0.977)),
                .init(1, -3.719)
            ]
        )
        let rotation = reduceMotion ? 0 : onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.55681, 0),
                .init(0.751, -360, easing: .cubic(1, -0.019, 0, 0.972)),
                .init(1, -360)
            ]
        )
        let flashOpacity = reduceMotion ? 0 : onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.05039, 1, easing: .cubic(1, -0.002, 0, 0.995)),
                .init(0.101, 0, easing: .cubic(1, 0, 0, 0.995)),
                .init(1, 0)
            ]
        )

        return OnboardingReferenceCanvas { metrics in
            ZStack {
                OnboardingLightLogo(scale: metrics.scale * CGFloat(scale))
                    .rotationEffect(.degrees(rotation))
                    .position(
                        metrics.point(
                            x: reduceMotion ? 196.5 : 200.219,
                            y: reduceMotion ? 81.8 : 395.103
                        )
                    )
                    .offset(x: metrics.length(translationX), y: metrics.length(translationY))

                Color.onboardingInkwell
                    .opacity(flashOpacity)
                    .mask {
                        Rectangle()
                            .padding(.top, metrics.safeAreaTop)
                    }
                    .ignoresSafeArea(edges: [.horizontal, .bottom])
            }
        }
    }
}

private struct OnboardingIntroFlowView: View {
    let phase: OnboardingPhase
    let reduceMotion: Bool
    let isCreateDisabled: Bool
    let isAllowDisabled: Bool
    let onCreate: () -> Void
    let onAllow: () -> Void
    let onDemo: () -> Void

    var body: some View {
        ZStack {
            OnboardingReferenceCanvas { metrics in
                ZStack {
                    OnboardingLightLogo(scale: metrics.scale * CGFloat(onboardingHeaderLogoScale))
                        .position(metrics.point(x: 196.5, y: 81.8))

                    OnboardingStepIndicator(
                        firstColor: phase == .photoIntoMusic
                            ? .onboardingInkwell
                            : .onboardingInactive,
                        secondColor: phase == .photoIntoMusic
                            ? .onboardingInactive
                            : .onboardingInkwell,
                        scale: metrics.scale
                    )
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.16)
                            : .snappy(duration: 0.42, extraBounce: 0),
                        value: phase
                    )
                    .position(metrics.point(x: 196.5, y: 109.54))
                }
            }
            .zIndex(1)

            Group {
                if phase == .photoIntoMusic {
                    OnboardingPhotoIntoMusicView(
                        reduceMotion: reduceMotion,
                        includesHeader: false,
                        isCreateDisabled: isCreateDisabled,
                        onCreate: onCreate
                    )
                    .id("photo-into-music")
                    .transition(introTransition)
                } else {
                    OnboardingPermissionPrimerView(
                        reduceMotion: reduceMotion,
                        includesHeader: false,
                        isAllowDisabled: isAllowDisabled,
                        onAllow: onAllow,
                        onDemo: onDemo
                    )
                    .id("permission-primer")
                    .transition(introTransition)
                }
            }
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.16)
                    : .snappy(duration: 0.42, extraBounce: 0),
                value: phase
            )
        }
    }

    private var introTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing),
            removal: .move(edge: .leading)
        )
    }
}

private struct OnboardingPhotoIntoMusicView: View {
    let reduceMotion: Bool
    let includesHeader: Bool
    let isCreateDisabled: Bool
    let onCreate: () -> Void

    @State private var startDate = Date()

    var body: some View {
        if reduceMotion {
            content(progress: 1, reduceMotion: true)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                content(
                    progress: min(max(context.date.timeIntervalSince(startDate) / 4, 0), 1),
                    reduceMotion: false
                )
            }
        }
    }

    private func content(progress: Double, reduceMotion: Bool) -> some View {
        let timelineProgress = reduceMotion ? 1 : progress
        let titleOpacity = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.25025, 1, easing: .cubic(0.5, 0, 0.5, 1)),
                .init(1, 1)
            ]
        )
        let titleTranslation = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.25025, 0),
                .init(0.49975, -11.108, easing: .cubic(0.42, 0, 0.58, 1)),
                .init(1, -11.108)
            ]
        )
        let imageOpacity = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.4995, 0),
                .init(0.625, 1, easing: .cubic(0, 0, 0.58, 1)),
                .init(1, 1)
            ]
        )
        let imageScale = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 1),
                .init(0.625, 1.66, easing: .cubic(0.5, 0, 0.5, 1)),
                .init(1, 1.66)
            ]
        )
        let indicatorOpacity = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.4995, 1, easing: .cubic(0.5, 0, 0.5, 1)),
                .init(1, 1)
            ]
        )
        let descriptionOpacity = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.55125, 0),
                .init(0.625, 1, easing: .cubic(0.5, 0, 0.5, 1)),
                .init(1, 1)
            ]
        )
        let ctaOpacity = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.75, 0),
                .init(0.8, 1, easing: .cubic(0.5, 0, 0.5, 1)),
                .init(1, 1)
            ]
        )
        let ctaVisible = reduceMotion || timelineProgress >= 0.8

        return OnboardingReferenceCanvas { metrics in
            ZStack {
                if includesHeader {
                    OnboardingLightLogo(scale: metrics.scale * CGFloat(onboardingHeaderLogoScale))
                        .position(metrics.point(x: 196.5, y: 81.8))

                    OnboardingStepIndicator(
                        firstColor: .onboardingInkwell,
                        secondColor: .onboardingInactive,
                        scale: metrics.scale
                    )
                    .opacity(indicatorOpacity)
                    .position(metrics.point(x: 196.5, y: 109.54))
                }

                Text("Your photos already\nhave a soundtrack")
                    .font(.custom("ZTTalk-Bold", size: metrics.length(22), relativeTo: .title2))
                    .foregroundStyle(Color.onboardingInkwell)
                    .multilineTextAlignment(.center)
                    .frame(width: metrics.length(300), height: metrics.length(58))
                    .opacity(titleOpacity)
                    .position(metrics.point(x: 196.71, y: 292.11))
                    .offset(y: metrics.length(titleTranslation))

                Image("OnboardingSample01")
                    .resizable()
                    .scaledToFill()
                    .frame(width: metrics.length(162.849), height: metrics.length(122.137))
                    .clipped()
                    .scaleEffect(CGFloat(imageScale))
                    .opacity(imageOpacity)
                    .position(metrics.point(x: 194.5, y: 426.0))

                Text("Colors become notes. The image sets the rhythm.")
                    .font(.custom("ZTTalk-Regular", size: metrics.length(17), relativeTo: .body))
                    .foregroundStyle(Color.onboardingInkwell)
                    .multilineTextAlignment(.center)
                    .frame(width: metrics.length(266.318), height: metrics.length(44))
                    .opacity(descriptionOpacity)
                    .position(metrics.point(x: 196.5, y: 564.19))

                OnboardingDarkPillButton(
                    title: "Create my first sound",
                    size: CGSize(width: metrics.length(249), height: metrics.length(42)),
                    font: .custom("ZTTalk-SemiBold", size: metrics.length(17), relativeTo: .body),
                    tracking: -0.43,
                    action: onCreate
                )
                .disabled(isCreateDisabled)
                .opacity(ctaOpacity)
                .allowsHitTesting(ctaVisible && !isCreateDisabled)
                .accessibilityHidden(!ctaVisible)
                .position(metrics.point(x: 196.5, y: 744.24))
            }
        }
    }
}

private struct OnboardingPermissionPrimerView: View {
    let reduceMotion: Bool
    let includesHeader: Bool
    let isAllowDisabled: Bool
    let onAllow: () -> Void
    let onDemo: () -> Void

    @State private var startDate = Date()

    var body: some View {
        if reduceMotion {
            content(progress: 1, reduceMotion: true)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                content(
                    progress: min(max(context.date.timeIntervalSince(startDate) / 2, 0), 1),
                    reduceMotion: false
                )
            }
        }
    }

    private func content(progress: Double, reduceMotion: Bool) -> some View {
        let timelineProgress = reduceMotion ? 1 : progress
        let iconOpacity = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0), .init(0.05, 0.5), .init(0.1, 0.567), .init(0.15, 0.75),
                .init(0.2, 0.912), .init(0.25, 0.991), .init(0.3, 1), .init(1, 1)
            ]
        )
        let iconScale = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 1),
                .init(0.025, 0.8, easing: .cubic(0.15, 0.85, 0.3, 1)),
                .init(0.0575, 0.8),
                .init(0.3, 1, easing: .cubic(0.3, 0, 0.5, 1)),
                .init(1, 1)
            ]
        )
        let textOpacity = timelineProgress < 0.25
            ? 0
            : timelineProgress < 0.5
                ? onboardingPermissionBounce((timelineProgress - 0.25) / 0.25)
                : 1
        let demoOpacity = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.6505, 0),
                .init(0.7505, 1, easing: .cubic(0.5, 0, 0.5, 1)),
                .init(1, 1)
            ]
        )
        let allowOpacity = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.6505, 0),
                .init(0.8995, 1, easing: .cubic(0.5, 0, 0.5, 1)),
                .init(1, 1)
            ]
        )
        let barProgress = onboardingMotionValue(
            at: timelineProgress,
            keyframes: [
                .init(0, 0),
                .init(0.25, 1, easing: .cubic(0.5, 0, 0.5, 1)),
                .init(1, 1)
            ]
        )
        let firstBar = onboardingBlendedColor(
            from: onboardingInkwellRGB,
            to: onboardingInactiveRGB,
            progress: barProgress
        )
        let secondBar = onboardingBlendedColor(
            from: onboardingInactiveRGB,
            to: onboardingInkwellRGB,
            progress: barProgress
        )
        let actionsVisible = reduceMotion || timelineProgress >= 0.7505

        return OnboardingReferenceCanvas { metrics in
            ZStack {
                if includesHeader {
                    OnboardingLightLogo(scale: metrics.scale * CGFloat(onboardingHeaderLogoScale))
                        .position(metrics.point(x: 197.3, y: 81.8))

                    OnboardingStepIndicator(
                        firstColor: firstBar,
                        secondColor: secondBar,
                        scale: metrics.scale
                    )
                    .position(metrics.point(x: 197.68, y: 109.54))
                }

                Image(systemName: "camera.fill")
                    .font(.system(size: metrics.length(72), weight: .regular))
                    .foregroundStyle(Color.onboardingInkwell)
                    .frame(width: metrics.length(84), height: metrics.length(72))
                    .opacity(iconOpacity)
                    .scaleEffect(CGFloat(iconScale))
                    .position(metrics.point(x: 196.5, y: 407))

                Text("We need your camera")
                    .font(.custom("ZTTalk-Bold", size: metrics.length(22), relativeTo: .title2))
                    .foregroundStyle(Color.onboardingInkwell)
                    .multilineTextAlignment(.center)
                    .frame(width: metrics.length(300), height: metrics.length(28))
                    .opacity(textOpacity)
                    .position(metrics.point(x: 196.5, y: 468.56))

                Text("We'll use it only to capture the photo that becomes your first song. Nothing ever leaves your device.")
                    .font(.custom("ZTTalk-Regular", size: metrics.length(17), relativeTo: .body))
                    .foregroundStyle(Color.onboardingInkwell)
                    .multilineTextAlignment(.center)
                    .frame(width: metrics.length(291.924), height: metrics.length(72))
                    .opacity(textOpacity)
                    .position(metrics.point(x: 196.5, y: 519.56))

                OnboardingDarkPillButton(
                    title: "Allow camera",
                    size: CGSize(width: metrics.length(156), height: metrics.length(42)),
                    font: .system(size: metrics.length(13), weight: .semibold),
                    tracking: -0.08,
                    action: onAllow
                )
                .disabled(isAllowDisabled)
                .opacity(allowOpacity)
                .allowsHitTesting(actionsVisible && !isAllowDisabled)
                .accessibilityHidden(!actionsVisible)
                .position(metrics.point(x: 196.5, y: 744))

                Button("Use a demo photo", action: onDemo)
                    .font(.system(size: metrics.length(13), weight: .semibold))
                    .tracking(-0.08)
                    .foregroundStyle(Color.onboardingInkwell)
                    .buttonStyle(.plain)
                    .disabled(isAllowDisabled)
                    .opacity(demoOpacity)
                    .allowsHitTesting(actionsVisible && !isAllowDisabled)
                    .accessibilityHidden(!actionsVisible)
                    .position(metrics.point(x: 197.3, y: 792.59))
            }
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
                        image: Image(item.imageName),
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
                    image: centerImage.map { Image(uiImage: $0) },
                    label: "Sua criação musical"
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
        .accessibilityLabel("Composição musical criada a partir da imagem")
    }
}

private struct OnboardingClusterCard: View {
    let color: Color
    let image: Image?
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color)
            .overlay {
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
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

private struct OnboardingClusterItem: Identifiable {
    let id: Int
    let label: String
    let imageName: String
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
    static let demoAssetName = "OnboardingSample02"
    static let centerFallbackColor = Color.onboardingCanvas

    static let clusterItems: [OnboardingClusterItem] = [
        OnboardingClusterItem(
            id: 0,
            label: "Camada visual um",
            imageName: "OnboardingSample03",
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
            label: "Camada visual dois",
            imageName: "OnboardingSample04",
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
            label: "Camada visual três",
            imageName: "OnboardingSample05",
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
            label: "Camada visual quatro",
            imageName: "OnboardingSample06",
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
        UIImage(named: demoAssetName)?.pngData() ?? Data()
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
