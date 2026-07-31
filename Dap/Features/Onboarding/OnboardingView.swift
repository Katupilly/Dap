import AVFoundation
import ImageIO
import SwiftUI
import UIKit

struct OnboardingView: View {
    let library: PhotoLibraryViewModel
    let onCompleted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: OnboardingPhase = .welcome
    @State private var controller: CameraController?
    @State private var input: OnboardingInput?
    @State private var centralDisplayImage: UIImage?
    @State private var assemblyTask: Task<Void, Never>?
    @State private var assemblyToken = UUID()
    @State private var captureToken = UUID()
    @State private var isCapturing = false
    @State private var isSwitchingCamera = false
    @State private var isRequestingPermission = false
    @State private var hasAnimatedCluster = false
    @State private var clusterAssembled = false
    @State private var assemblyMessage = "Lendo as cores da sua foto…"
    @State private var captureFeedback = 0
    @State private var completionFeedback = 0
    @State private var permissionIssue: OnboardingPermissionIssue = .denied
    @State private var failure: OnboardingFailure?

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
            assemblyTask?.cancel()
            assemblyTask = nil
            library.stopTransientPlayback()
            stopCamera()
        }
        .sensoryFeedback(.selection, trigger: captureFeedback)
        .sensoryFeedback(.success, trigger: completionFeedback)
        .statusBarHidden(true)
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
        case .welcome:
            VStack(spacing: 18) {
                OnboardingMechanismView()

                Text("Toda foto tem uma música escondida nela.")
                    .font(.custom("ZTTalk-Bold", size: 25, relativeTo: .title2))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("As cores viram notas. A imagem cria o ritmo.")
                    .font(.custom("ZTTalk-Medium", size: 16, relativeTo: .body))
                    .foregroundStyle(.white.opacity(0.76))
                    .multilineTextAlignment(.center)
            }

        case .permissionPrimer:
            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)

                Text("Precisamos da câmera")
                    .font(.custom("ZTTalk-Bold", size: 25, relativeTo: .title2))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Vamos usar sua câmera só para capturar a foto que vira sua primeira música. Nada é enviado para fora do dispositivo durante esse processo.")
                    .font(.custom("ZTTalk-Medium", size: 16, relativeTo: .body))
                    .foregroundStyle(.white.opacity(0.76))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
            }

        case .assembling, .ready:
            OnboardingPhotoClusterView(
                centerImage: centralDisplayImage,
                isAssembled: clusterAssembled,
                reduceMotion: reduceMotion,
                showsPulse: phase == .ready
            )

        case .capture:
            captureContent

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

                if controller != nil {
                    Button {
                        Task { await switchCamera() }
                    } label: {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.38), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isCapturing || isSwitchingCamera)
                    .accessibilityLabel("Virar câmera")
                    .accessibilityHint("Alterna entre a câmera traseira e a frontal.")
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(maxWidth: 340)
        }
        .accessibilityLabel("Pré-visualização da câmera")
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
        case .welcome:
            primaryButton("Criar meu primeiro som", systemImage: "arrow.right") {
                withAnimation(.easeOut(duration: 0.18)) {
                    phase = .permissionPrimer
                }
            }

        case .permissionPrimer:
            VStack(spacing: 12) {
                primaryButton("Permitir câmera", systemImage: "camera.fill") {
                    Task { await requestCameraAccess() }
                }
                .disabled(isRequestingPermission)

                secondaryButton("Usar uma imagem de demonstração") {
                    beginAssembly(.demo)
                }
                .disabled(isRequestingPermission)
            }

        case .capture:
            VStack(spacing: 16) {
                Button {
                    Task { await capturePhoto() }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 4)
                            .frame(width: 88, height: 88)

                        if isCapturing {
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
                .disabled(controller == nil || isCapturing)
                .accessibilityLabel("Tirar foto")
                .accessibilityHint("Captura a foto que será transformada em música.")

                secondaryButton("Usar uma imagem de demonstração") {
                    beginAssembly(.demo)
                }
                .disabled(isCapturing)
            }

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
                        beginAssembly(.demo)
                    }
                }

                secondaryButton(permissionIssue == .denied ? "Continuar com demonstração" : "Verificar novamente") {
                    if permissionIssue == .denied {
                        beginAssembly(.demo)
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
                    beginAssembly(.demo)
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
        guard phase == .permissionPrimer, !isRequestingPermission else { return }
        isRequestingPermission = true
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
    private func capturePhoto() async {
        guard phase == .capture,
              let controller,
              !isCapturing,
              !isSwitchingCamera else {
            return
        }

        let token = UUID()
        captureToken = token
        isCapturing = true
        captureFeedback += 1
        defer { isCapturing = false }

        do {
            let data = try await controller.capturePhoto(flashMode: .off)
            guard phase == .capture, captureToken == token else { return }

            stopCamera(invalidateCapture: false)
            input = .captured(data)
            setPreview(data)
            withAnimation(.easeOut(duration: 0.18)) {
                phase = .review
            }
        } catch {
            guard captureToken == token else { return }
            failure = .captureFailed
            withAnimation(.easeOut(duration: 0.16)) {
                phase = .technicalError
            }
        }
    }

    @MainActor
    private func switchCamera() async {
        guard phase == .capture,
              let controller,
              !isCapturing,
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
        beginAssembly(input)
    }

    @MainActor
    private func retakePhoto() async {
        guard phase == .review else { return }

        assemblyTask?.cancel()
        input = nil
        centralDisplayImage = nil
        clusterAssembled = false
        hasAnimatedCluster = false
        withAnimation(.easeOut(duration: 0.18)) {
            phase = .capture
        }
        await startCameraIfNeeded()
    }

    @MainActor
    private func beginAssembly(_ input: OnboardingInput) {
        guard phase != .assembling, phase != .ready else { return }

        assemblyTask?.cancel()
        let token = UUID()
        assemblyToken = token
        self.input = input
        failure = nil
        clusterAssembled = false
        hasAnimatedCluster = false
        assemblyMessage = "Lendo as cores da sua foto…"

        if case .demo = input {
            setPreview(OnboardingTemporaryArtwork.fallbackImageData())
        }
        stopCamera()

        withAnimation(.easeOut(duration: 0.18)) {
            phase = .assembling
        }

        assemblyTask = Task { @MainActor [input, token] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                guard isCurrentAssembly(token) else { return }
                assemblyMessage = "Transformando em melodia…"

                let sound: PhotoSound
                switch input {
                case .captured(let data):
                    guard let imported = try await library.importPhotoSoundData(data) else {
                        throw OnboardingImportError.alreadyImporting
                    }
                    sound = imported
                case .demo:
                    let processed = try await PhotoMusicPipeline.process(
                        imageData: OnboardingTemporaryArtwork.fallbackImageData()
                    )
                    sound = processed.sound
                }

                guard isCurrentAssembly(token) else { return }
                library.playTransientSequence(sound.sequence)
                withAnimation(clusterAnimation) {
                    hasAnimatedCluster = true
                    clusterAssembled = true
                }
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
    private func setPreview(_ data: Data) {
        centralDisplayImage = OnboardingTemporaryArtwork.displayImage(from: data)
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
                beginAssembly(input)
            } else {
                phase = .permissionPrimer
            }
        case .generationFailed:
            beginAssembly(.demo)
        case .permissionCheckFailed, nil:
            phase = .permissionPrimer
        }
    }

    @MainActor
    private func isCurrentAssembly(_ token: UUID) -> Bool {
        !Task.isCancelled && phase == .assembling && assemblyToken == token
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
    case welcome
    case permissionPrimer
    case capture
    case review
    case assembling
    case ready
    case permissionDenied
    case technicalError
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

private struct OnboardingMechanismView: View {
    var body: some View {
        HStack(spacing: 8) {
            if let image = OnboardingTemporaryArtwork.demoImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 104, height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))

            OnboardingColorStrip()
                .frame(width: 34, height: 130)

            Image(systemName: "arrow.right")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))

            OnboardingSequenceGraphic()
                .frame(width: 88, height: 130)
        }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uma foto se transforma em cores e depois em uma sequência musical")
    }
}

private struct OnboardingColorStrip: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(red: 0.94, green: 0.20, blue: 0.32))
            Rectangle().fill(Color(red: 0.12, green: 0.72, blue: 0.86))
            Rectangle().fill(Color(red: 0.98, green: 0.72, blue: 0.18))
            Rectangle().fill(Color(red: 0.44, green: 0.34, blue: 0.96))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct OnboardingSequenceGraphic: View {
    private let lengths: [CGFloat] = [0.72, 0.42, 0.88, 0.56, 0.78, 0.34, 0.64, 0.48]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(lengths.enumerated()), id: \.offset) { index, length in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index.isMultiple(of: 2) ? Color(red: 0.12, green: 0.72, blue: 0.86) : .white.opacity(0.72))
                        .frame(width: 68 * length, height: 7)
                    Circle()
                        .fill(.white.opacity(0.42))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    static let demoImage = displayImage(from: fallbackImageData())

    static let clusterItems: [OnboardingClusterItem] = [
        OnboardingClusterItem(
            id: 0,
            label: "Camada visual um",
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
