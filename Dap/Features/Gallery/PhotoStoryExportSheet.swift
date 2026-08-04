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
            notes: sound.sequence.notes.map { Note(step: $0.step, row: $0.row) },
            palette: RetroCoverRenderer.tonalPalette(for: pitch)
        )
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
        template: StoryShareTemplate,
        snapshot: PhotoStoryExportSnapshot
    ) async throws -> PhotoExportPayload {
        guard let baseImage = UIImage(data: snapshot.imageData, scale: 1),
              baseImage.cgImage != nil else {
            throw PhotoStoryRenderError.invalidImage
        }

        let image = PhotoPaperExportRenderer().render(image: baseImage) ?? baseImage

        switch template {
        case .plain:
            guard let cgImage = image.cgImage else {
                throw PhotoStoryRenderError.renderFailed
            }
            return PhotoExportPayload(
                image: image,
                pngData: image.pngData() ?? snapshot.imageData,
                pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
            )
        case .dap:
            let result = try await PhotoStoryRenderer().render(
                snapshot: snapshot,
                image: image
            )
            return PhotoExportPayload(
                image: result.image,
                pngData: result.pngData,
                pixelSize: result.pixelSize
            )
        }
    }
}

struct PhotoStoryExportSheet: View {
    let snapshot: PhotoStoryExportSnapshot

    @Environment(\.dismiss) private var dismiss
    @State private var selection: StoryShareTemplate = .plain
    @State private var payloads: [StoryShareTemplate: PhotoExportPayload] = [:]
    @State private var failedTemplates: Set<StoryShareTemplate> = []
    @State private var isShowingShareSheet = false
    @State private var instagramShareState = InstagramStoryShareState.idle
    @State private var errorMessage: String?
    @State private var renderTask: Task<Void, Never>?
    @State private var renderToken = UUID()

    private let renderer = PhotoExportRenderer()
    private let instagramService = InstagramStoryShareService()

    var body: some View {
        ZStack(alignment: .top) {
            StoryExportChromeBackground()

            StoryShareSurface(
                previews: StoryShareTemplate.allCases.map { template in
                    StorySharePreview(
                        template: template,
                        image: payloads[template]?.image,
                        isLoading: payloads[template] == nil && !failedTemplates.contains(template)
                    )
                },
                selection: selection,
                isInstagramAvailable: instagramService.isInstagramStoriesAvailable,
                isStoriesLoading: instagramShareState == .opening,
                isShareLoading: false,
                isStoriesEnabled: payloads[selection] != nil,
                isShareEnabled: payloads[selection] != nil,
                onSelect: { selection = $0 },
                onStories: shareToInstagram,
                onShare: { isShowingShareSheet = true }
            )
            .padding(.top, 62)

            StoryShareHeader(title: "Share") {
                dismiss()
            }
        }
        .task { schedulePreparation() }
        .onDisappear {
            renderTask?.cancel()
            renderTask = nil
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let payload = payloads[selection] {
                NativeImageShareViewController(image: payload.image)
            }
        }
        .alert("Couldn't Share to Instagram", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func schedulePreparation() {
        renderTask?.cancel()
        let token = UUID()
        renderToken = token
        payloads = [:]
        failedTemplates = []
        isShowingShareSheet = false
        instagramShareState = .idle
        errorMessage = nil
        renderTask = Task { @MainActor [snapshot, token] in
            await prepare(snapshot: snapshot, token: token)
        }
    }

    @MainActor
    private func prepare(snapshot: PhotoStoryExportSnapshot, token: UUID) async {
        for template in StoryShareTemplate.allCases {
            do {
                let payload = try await renderer.render(template: template, snapshot: snapshot)
                guard !Task.isCancelled, token == renderToken else { return }
                payloads[template] = payload
            } catch is CancellationError {
                return
            } catch {
                guard token == renderToken else { return }
                failedTemplates.insert(template)
                if template == selection {
                    errorMessage = (error as? LocalizedError)?.errorDescription
                }
            }
        }
        renderTask = nil
    }

    private func shareToInstagram() {
        guard instagramShareState != .opening,
              let payload = payloads[selection] else { return }

        instagramShareState = .opening
        errorMessage = nil
        Task { @MainActor [payload] in
            do {
                try await instagramService.share(image: payload.image)
                instagramShareState = .idle
            } catch {
                instagramShareState = .failed
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Could not open Instagram Stories."
            }
        }
    }
}

private enum InstagramStoryShareState: Equatable {
    case idle
    case opening
    case failed
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

        return try await render(snapshot: snapshot, image: image)
    }

    @MainActor
    func render(
        snapshot: PhotoStoryExportSnapshot,
        image: UIImage
    ) async throws -> PhotoStoryRenderResult {

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
