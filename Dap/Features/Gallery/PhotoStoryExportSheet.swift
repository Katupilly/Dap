import SwiftUI
import UIKit

struct PhotoStoryExportSnapshot: Identifiable, Sendable {
    struct Note: Identifiable, Sendable {
        let step: Int
        let row: Int

        var id: String { "\(step)-\(row)" }
    }

    let id: UUID
    let imageData: Data
    let title: String
    let root: String
    let scale: String
    let bpm: Int
    let notes: [Note]
    let palette: ColorPalette

    private init(
        id: UUID,
        imageData: Data,
        title: String,
        root: String,
        scale: String,
        bpm: Int,
        notes: [Note],
        palette: ColorPalette
    ) {
        self.id = id
        self.imageData = imageData
        self.title = title
        self.root = root
        self.scale = scale
        self.bpm = bpm
        self.notes = notes
        self.palette = palette
    }

    init?(sound: PhotoSound, coverData: Data?) {
        guard let coverData else { return nil }

        let pitch = PitchClass(rawValue: sound.sequence.harmony.rootPitchClass) ?? .c
        self.init(
            id: sound.id,
            imageData: coverData,
            title: sound.displayTitle,
            root: pitch.symbol,
            scale: sound.sequence.harmony.scale.displayName,
            bpm: sound.sequence.harmony.bpm,
            notes: sound.sequence.notes.map {
                Note(step: $0.step, row: $0.row)
            },
            palette: RetroCoverRenderer.tonalPalette(for: pitch)
        )
    }
}

enum PhotoShareFormat: String, CaseIterable, Identifiable, Sendable {
    case dapCard
    case photoOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .dapCard: "Dap Card"
        case .photoOnly: "Photo Only"
        }
    }
}

enum PhotoExportFormat: String, CaseIterable, Identifiable, Sendable {
    case photo
    case story

    var id: Self { self }

    var title: String {
        switch self {
        case .photo: "Foto"
        case .story: "Story"
        }
    }
}

struct PhotoExportPayload {
    let image: UIImage
    let pngData: Data
    let pixelSize: CGSize
}

struct PhotoExportRenderer {
    @MainActor
    func render(
        format: PhotoShareFormat,
        snapshot: PhotoStoryExportSnapshot
    ) async throws -> PhotoExportPayload {
        switch format {
        case .photoOnly:
            return try renderPhoto(snapshot: snapshot)
        case .dapCard:
            let result = try await PhotoStoryRenderer().render(snapshot: snapshot)
            return PhotoExportPayload(
                image: result.image,
                pngData: result.pngData,
                pixelSize: result.pixelSize
            )
        }
    }

    @MainActor
    func render(
        format: PhotoExportFormat,
        snapshot: PhotoStoryExportSnapshot
    ) async throws -> PhotoExportPayload {
        switch format {
        case .photo:
            return try renderPhoto(snapshot: snapshot)
        case .story:
            let result = try await PhotoStoryRenderer().render(snapshot: snapshot)
            return PhotoExportPayload(
                image: result.image,
                pngData: result.pngData,
                pixelSize: result.pixelSize
            )
        }
    }

    private func renderPhoto(snapshot: PhotoStoryExportSnapshot) throws -> PhotoExportPayload {
        guard let image = UIImage(data: snapshot.imageData, scale: 1),
              let cgImage = image.cgImage else {
            throw PhotoStoryRenderError.invalidImage
        }

        return PhotoExportPayload(
            image: image,
            pngData: snapshot.imageData,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

private let photoStoryExportHeaderHeight: CGFloat = 72

struct PhotoStoryExportSheet: View {
    let snapshot: PhotoStoryExportSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var format: PhotoShareFormat = .dapCard
    @State private var phase = Phase.preparing
    @State private var payload: PhotoExportPayload?
    @State private var isShowingShareSheet = false
    @State private var instagramShareState = InstagramStoryShareState.idle
    @State private var errorMessage: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var renderToken = UUID()

    private let renderer = PhotoExportRenderer()
    private let instagramService = InstagramStoryShareService()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                StoryExportChromeBackground()

                VStack(spacing: 0) {
                    ScrollView {
                        formatPicker
                        content
                    }
                    .safeAreaInset(edge: .top, spacing: 24) {
                        Color.clear
                            .frame(height: photoStoryExportHeaderHeight)
                    }

                    footer
                }

                StoryExportTopBlurFade(height: 112)

                PhotoStoryExportHeader {
                    dismiss()
                }
            }
        }
        .task {
            schedulePreparation()
        }
        .onChange(of: format) { _, _ in
            schedulePreparation()
        }
        .onDisappear {
            renderTask?.cancel()
            renderTask = nil
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let payload {
                PhotoShareActivityViewController(
                    payload: payload
                )
            }
    }
}

private struct PhotoStoryExportHeader: View {
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Text("Compartilhar foto")
                .font(.custom("ZTTalk-Bold", size: 18, relativeTo: .headline))
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(StoryHeaderGlassButtonStyle())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(height: photoStoryExportHeaderHeight, alignment: .top)
}
}

private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Formato")
                .font(.custom("ZTTalk-Bold", size: 14, relativeTo: .subheadline))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                formatButton(.dapCard)
                formatButton(.photoOnly)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            VStack(spacing: 14) {
                ProgressView()
                Text("Preparing \(format.title)")
                    .font(.custom("ZTTalk-Bold", size: 16, relativeTo: .subheadline))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 120)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preparing export")
            .accessibilityValue(format.title)
        case .ready:
            if let payload {
                Image(uiImage: payload.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
                    .accessibilityLabel("Export preview \(format.title)")
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 28)
            }
        case .failed:
            StoryExportErrorView(
                message: errorMessage ?? "Could not prepare this export.",
                onTryAgain: schedulePreparation
            )
            .padding(.top, 40)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if phase == .ready, let payload {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                Button {
                    isShowingShareSheet = true
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(StoryPrimaryButtonStyle())
                .accessibilityHint("Opens the system share sheet for the selected format.")

                let isInstagramAvailable = instagramService.isInstagramStoriesAvailable
                Button {
                    shareToInstagram(payload)
                } label: {
                    Label(instagramButtonTitle(isAvailable: isInstagramAvailable), systemImage: "camera")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(StorySecondaryButtonStyle())
                .disabled(instagramShareState == .opening)
                .accessibilityHint(
                    isInstagramAvailable
                        ? "Opens Instagram Stories."
                        : "Shows an Instagram availability message."
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private func formatButton(_ candidate: PhotoShareFormat) -> some View {
        Button {
            guard phase != .preparing else { return }
            format = candidate
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                formatThumbnail(candidate)

                HStack(spacing: 6) {
                    Text(candidate.title)
                        .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))

                    if format == candidate {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                    }
                }
                .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        format == candidate ? Color.primary.opacity(0.72) : Color.primary.opacity(0.14),
                        lineWidth: format == candidate ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .preparing)
        .accessibilityLabel(candidate.title)
        .accessibilityValue(format == candidate ? "Selected" : "Not selected")
        .accessibilityAddTraits(format == candidate ? .isSelected : [])
    }

    @ViewBuilder
    private func formatThumbnail(_ candidate: PhotoShareFormat) -> some View {
        if candidate == format, let image = payload?.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(height: 86)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(0.08))
                .frame(height: 86)
                .overlay {
                    Image(systemName: candidate == .dapCard ? "rectangle.portrait" : "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    @MainActor
    private func schedulePreparation() {
        renderTask?.cancel()
        let token = UUID()
        renderToken = token
        phase = .preparing
        payload = nil
        isShowingShareSheet = false
        instagramShareState = .idle
        errorMessage = nil
        renderTask = Task { @MainActor [format, token] in
            await prepare(format: format, token: token)
        }
    }

    @MainActor
    private func prepare(format: PhotoShareFormat, token: UUID) async {
        phase = .preparing
        payload = nil
        errorMessage = nil

        do {
            let rendered = try await renderer.render(format: format, snapshot: snapshot)
            guard !Task.isCancelled, token == renderToken, format == self.format else { return }
            try Task.checkCancellation()
            guard token == renderToken, format == self.format else { return }
            payload = rendered
            phase = .ready
            renderTask = nil
        } catch is CancellationError {
            return
        } catch {
            guard token == renderToken, format == self.format else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Não foi possível preparar esta exportação."
            phase = .failed
            renderTask = nil
        }
    }

    private func shareToInstagram(_ payload: PhotoExportPayload) {
        guard instagramShareState != .opening else { return }

        let selectedFormat = format
        instagramShareState = .opening
        errorMessage = nil
        Task { @MainActor [payload, selectedFormat] in
            do {
                try await instagramService.share(image: payload.image)
                guard selectedFormat == format else { return }
                instagramShareState = .idle
            } catch {
                guard selectedFormat == format else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Could not open Instagram Stories."
                instagramShareState = .failed(message)
                errorMessage = message
            }
        }
    }

    private func instagramButtonTitle(isAvailable: Bool) -> String {
        guard isAvailable else { return "Instagram Not Installed" }

        switch instagramShareState {
        case .idle:
            return "Share to Instagram"
        case .opening:
            return "Opening Instagram…"
        case .failed:
            return "Try Instagram Again"
        }
    }

    private enum Phase {
        case preparing
        case ready
        case failed
    }
}

private enum InstagramStoryShareState: Equatable {
    case idle
    case opening
    case failed(String)
}

private struct PhotoShareActivityViewController: UIViewControllerRepresentable {
    let payload: PhotoExportPayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [payload.image],
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

struct StoryExportErrorView: View {
    let message: String
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
                .multilineTextAlignment(.center)

            Button(action: onTryAgain) {
                Text("Try Again")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(StoryPrimaryButtonStyle())

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }
}

struct PhotoStoryRenderResult {
    let image: UIImage
    let pngData: Data
    let pixelSize: CGSize
}

enum PhotoStoryRenderError: Error, LocalizedError {
    case invalidImage
    case renderFailed
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Could not read this photo's image."
        case .renderFailed:
            "Could not render this photo story."
        case .pngEncodingFailed:
            "Could not prepare this photo story for sharing."
        }
    }
}

struct PhotoStoryRenderer {
    static let outputPixelSize = CGSize(width: 1080, height: 1920)

    @MainActor
    func render(snapshot: PhotoStoryExportSnapshot) async throws -> PhotoStoryRenderResult {
        guard let image = UIImage(data: snapshot.imageData, scale: 1) else {
            throw PhotoStoryRenderError.invalidImage
        }

        let content = PhotoStoryExportView(snapshot: snapshot, image: image)
            .frame(width: Self.outputPixelSize.width, height: Self.outputPixelSize.height)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 1)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(Self.outputPixelSize)
        renderer.scale = 1
        renderer.isOpaque = true

        guard let renderedImage = renderer.uiImage,
              let cgImage = renderedImage.cgImage else {
            throw PhotoStoryRenderError.renderFailed
        }
        guard let pngData = renderedImage.pngData() else {
            throw PhotoStoryRenderError.pngEncodingFailed
        }

        return PhotoStoryRenderResult(
            image: renderedImage,
            pngData: pngData,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }
}

private struct PhotoStoryExportView: View {
    let snapshot: PhotoStoryExportSnapshot
    let image: UIImage

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 38) {
                titleBlock

                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 708, height: 844)
                    .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 42, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.34), radius: 48, y: 30)
                    .frame(maxWidth: .infinity)

                facts

                sequencer

                Spacer(minLength: 0)

                signature
            }
            .padding(.top, 180)
            .padding(.horizontal, 82)
            .padding(.bottom, 190)
        }
        .frame(width: PhotoStoryRenderer.outputPixelSize.width, height: PhotoStoryRenderer.outputPixelSize.height)
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(jamRGB: snapshot.palette.shadow),
                    Color(jamRGB: snapshot.palette.dark).opacity(0.92),
                    Color(jamRGB: snapshot.palette.base).opacity(0.74)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [.black.opacity(0.06), .black.opacity(0.36)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("DAP PHOTO")
                .font(.custom("ZTTalk-Bold", size: 24, relativeTo: .caption))
                .tracking(3.8)
                .foregroundStyle(.white.opacity(0.52))

            Text(snapshot.title)
                .font(.custom("ZTTalk-Bold", size: 82, relativeTo: .largeTitle))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
    }

    private var facts: some View {
        HStack(spacing: 14) {
            fact("ROOT", snapshot.root)
            fact("SCALE", snapshot.scale)
            fact("BPM", "\(snapshot.bpm)")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom("ZTTalk-Bold", size: 16, relativeTo: .caption))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.custom("ZTTalk-Bold", size: 27, relativeTo: .headline))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sequencer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SEQUENCE")
                .font(.custom("ZTTalk-Bold", size: 22, relativeTo: .headline))
                .tracking(1.4)
                .foregroundStyle(.white)

            VStack(spacing: 8) {
                ForEach((0..<MusicSequence.rows).reversed(), id: \.self) { row in
                    HStack(spacing: 5) {
                        ForEach(0..<MusicSequence.steps, id: \.self) { step in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isActive(step: step, row: row) ? Color(jamRGB: snapshot.palette.highlight).opacity(0.92) : .white.opacity(0.14))
                                .frame(maxWidth: .infinity)
                                .frame(height: 12)
                        }
                    }
                }
            }
        }
        .padding(26)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1.5)
        }
    }

    private var signature: some View {
        Text("Made with Dap")
            .font(.custom("ZTTalk-Bold", size: 24, relativeTo: .footnote))
            .foregroundStyle(.white.opacity(0.62))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func isActive(step: Int, row: Int) -> Bool {
        snapshot.notes.contains { $0.step == step && $0.row == row }
    }
}
