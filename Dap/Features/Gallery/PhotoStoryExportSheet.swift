import SwiftUI
import UIKit

struct PhotoStoryExportSnapshot: Identifiable, Sendable {
    let id: UUID
    let imageData: Data
    let title: String
    let root: String
    let scale: String
    let bpm: Int
    let palette: ColorPalette

    private init(
        id: UUID,
        imageData: Data,
        title: String,
        root: String,
        scale: String,
        bpm: Int,
        palette: ColorPalette
    ) {
        self.id = id
        self.imageData = imageData
        self.title = title
        self.root = root
        self.scale = scale
        self.bpm = bpm
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
            palette: RetroCoverRenderer.tonalPalette(for: pitch)
        )
    }
}

struct PhotoExportPayload {
    let image: UIImage
    let pngData: Data
    let pixelSize: CGSize
}

struct PhotoStoryExportLayout {
    static let canvasSize = CGSize(width: 1080, height: 1920)
    static let photoFrame = CGRect(x: 120, y: 380, width: 840, height: 1000)
    static let photoCornerRadius: CGFloat = 50
    static let eyebrowTop: CGFloat = 223.51
    static let titleTop: CGFloat = 254.51
    static let titleMaxWidth: CGFloat = 840
    static let metadataFrame = CGRect(x: 169.5, y: 1484, width: 741, height: 62)
    static let signatureTop: CGFloat = 1749.75
    static let previewAspectRatio = canvasSize.width / canvasSize.height
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
    @State private var photoSaveToastEvent: PhotoSaveToastEvent?
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
                onShare: { isShowingShareSheet = true },
                aspectRatio: PhotoStoryExportLayout.previewAspectRatio
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
                NativeImageShareViewController(
                    image: payload.image,
                    onSaveResult: { result in
                        photoSaveToastEvent = PhotoSaveToastEvent.make(for: result)
                    },
                    onDismiss: { isShowingShareSheet = false }
                )
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
        .photoSaveToast($photoSaveToastEvent)
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
            .frame(width: PhotoStoryExportLayout.canvasSize.width, height: PhotoStoryExportLayout.canvasSize.height)
            .environment(\.colorScheme, .dark)
            .environment(\.displayScale, 1)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(PhotoStoryExportLayout.canvasSize)
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
        let gradient = PhotoStoryBackgroundGradient(palette: snapshot.palette)
        let headerForeground = foregroundColors(
            atNormalizedY: (CGFloat(240) + CGFloat(320)) / 2 / PhotoStoryExportLayout.canvasSize.height,
            gradient: gradient
        )
        let metadataForeground = foregroundColors(
            atNormalizedY: PhotoStoryExportLayout.metadataFrame.midY / PhotoStoryExportLayout.canvasSize.height,
            gradient: gradient
        )
        let signatureForeground = foregroundColors(
            atNormalizedY: (CGFloat(1750) + CGFloat(1781)) / 2 / PhotoStoryExportLayout.canvasSize.height,
            gradient: gradient
        )

        ZStack(alignment: .top) {
            gradient.view
            photoContainer

            Text("DAP PHOTO")
                .font(.custom("ZTTalk-Medium", size: 24))
                .foregroundStyle(headerForeground.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, PhotoStoryExportLayout.eyebrowTop)

            Text(snapshot.title)
                .font(.custom("ZTTalk-Medium", size: 48))
                .foregroundStyle(headerForeground.primary)
                .frame(width: PhotoStoryExportLayout.titleMaxWidth, alignment: .center)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, PhotoStoryExportLayout.titleTop)

            metadata(foreground: metadataForeground)

            Text("Made with Dap")
                .font(.custom("ZTTalk-SemiBold", size: 24))
                .foregroundStyle(signatureForeground.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, PhotoStoryExportLayout.signatureTop)
        }
        .frame(width: PhotoStoryExportLayout.canvasSize.width, height: PhotoStoryExportLayout.canvasSize.height)
        .environment(\.colorScheme, .dark)
    }

    private var photoContainer: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(
                width: PhotoStoryExportLayout.photoFrame.width,
                height: PhotoStoryExportLayout.photoFrame.height
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PhotoStoryExportLayout.photoCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: PhotoStoryExportLayout.photoCornerRadius,
                    style: .continuous
                )
                    .stroke(.white.opacity(0.18), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.34), radius: 48, y: 30)
            .position(
                x: PhotoStoryExportLayout.photoFrame.midX,
                y: PhotoStoryExportLayout.photoFrame.midY
            )
    }

    private func metadata(foreground: AdaptiveStoryForeground) -> some View {
        HStack(spacing: 0) {
            metadataColumn("ROOT", snapshot.root, foreground: foreground)
            Spacer(minLength: 0)
            metadataColumn("SCALE", snapshot.scale, foreground: foreground)
            Spacer(minLength: 0)
            metadataColumn("BPM", "\(snapshot.bpm)", foreground: foreground)
        }
        .frame(
            width: PhotoStoryExportLayout.metadataFrame.width,
            height: PhotoStoryExportLayout.metadataFrame.height,
            alignment: .topLeading
        )
        .position(
            x: PhotoStoryExportLayout.metadataFrame.midX,
            y: PhotoStoryExportLayout.metadataFrame.minY + PhotoStoryExportLayout.metadataFrame.height / 2
        )
    }

    private func metadataColumn(
        _ label: String,
        _ value: String,
        foreground: AdaptiveStoryForeground
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom("ZTTalk-SemiBold", size: 24))
                .foregroundStyle(foreground.secondary)
            Text(value)
                .font(.custom("ZTTalk-SemiBold", size: 24))
                .foregroundStyle(foreground.primary)
                .lineLimit(1)
        }
    }
}

struct AdaptiveStoryForeground {
    let primary: Color
    let secondary: Color
}

func foregroundColors(
    atNormalizedY normalizedY: CGFloat,
    gradient: PhotoStoryBackgroundGradient
) -> AdaptiveStoryForeground {
    let luminance = gradient.relativeLuminance(atNormalizedY: Double(normalizedY))
    let blackContrast = (luminance + 0.05) / 0.05
    let whiteContrast = 1.05 / (luminance + 0.05)
    let primary = blackContrast > whiteContrast ? Color.black : Color.white
    return AdaptiveStoryForeground(primary: primary, secondary: primary.opacity(0.60))
}

struct PhotoStoryBackgroundGradient {
    private struct Stop {
        let color: RGBColor
        let opacity: Double
        let location: Double

        var swiftUIStop: Gradient.Stop {
            Gradient.Stop(
                color: Color(jamRGB: color).opacity(opacity),
                location: location
            )
        }
    }

    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        static let black = Self(red: 0, green: 0, blue: 0, alpha: 1)

        init(color: RGBColor, opacity: Double) {
            self.init(
                red: Double(color.red) / 255,
                green: Double(color.green) / 255,
                blue: Double(color.blue) / 255,
                alpha: opacity
            )
        }

        init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        func composited(over background: Self) -> Self {
            let outputAlpha = alpha + background.alpha * (1 - alpha)
            guard outputAlpha > 0 else { return Self(red: 0, green: 0, blue: 0, alpha: 0) }

            return Self(
                red: (red * alpha + background.red * background.alpha * (1 - alpha)) / outputAlpha,
                green: (green * alpha + background.green * background.alpha * (1 - alpha)) / outputAlpha,
                blue: (blue * alpha + background.blue * background.alpha * (1 - alpha)) / outputAlpha,
                alpha: outputAlpha
            )
        }

        var relativeLuminance: Double {
            func linearized(_ component: Double) -> Double {
                component <= 0.03928
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }

            return 0.2126 * linearized(red)
                + 0.7152 * linearized(green)
                + 0.0722 * linearized(blue)
        }
    }

    private let diagonalStops: [Stop]
    private let overlayStops: [Stop]

    init(palette: ColorPalette) {
        diagonalStops = [
            Stop(color: palette.shadow, opacity: 1, location: 0),
            Stop(color: palette.dark, opacity: 0.92, location: 0.5),
            Stop(color: palette.base, opacity: 0.74, location: 1)
        ]
        overlayStops = [
            Stop(color: .black, opacity: 0.06, location: 0),
            Stop(color: .black, opacity: 0.36, location: 1)
        ]
    }

    @ViewBuilder
    var view: some View {
        ZStack {
            LinearGradient(
                stops: diagonalStops.map(\.swiftUIStop),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                stops: overlayStops.map(\.swiftUIStop),
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    func relativeLuminance(atNormalizedY normalizedY: Double) -> Double {
        effectiveColor(atNormalizedY: normalizedY).relativeLuminance
    }

    private func effectiveColor(atNormalizedY normalizedY: Double) -> RGBA {
        let y = min(max(normalizedY, 0), 1)
        let diagonal = sample(diagonalStops, at: diagonalLocation(atNormalizedY: y))
            .composited(over: .black)
        let overlay = sample(overlayStops, at: y)
        return overlay.composited(over: diagonal)
    }

    private func diagonalLocation(atNormalizedY normalizedY: Double) -> Double {
        let width = Double(PhotoStoryExportLayout.canvasSize.width)
        let height = Double(PhotoStoryExportLayout.canvasSize.height)
        return (0.5 * width * width + normalizedY * height * height)
            / (width * width + height * height)
    }

    private func sample(_ stops: [Stop], at location: Double) -> RGBA {
        guard let first = stops.first else { return .black }
        guard let last = stops.last else { return .black }
        let position = min(max(location, first.location), last.location)

        guard let upperIndex = stops.firstIndex(where: { $0.location >= position }) else {
            return RGBA(color: last.color, opacity: last.opacity)
        }
        guard upperIndex > 0 else {
            return RGBA(color: first.color, opacity: first.opacity)
        }

        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let span = upper.location - lower.location
        let ratio = span == 0 ? 0 : (position - lower.location) / span
        return RGBA(
            red: interpolate(Double(lower.color.red) / 255, Double(upper.color.red) / 255, ratio),
            green: interpolate(Double(lower.color.green) / 255, Double(upper.color.green) / 255, ratio),
            blue: interpolate(Double(lower.color.blue) / 255, Double(upper.color.blue) / 255, ratio),
            alpha: interpolate(lower.opacity, upper.opacity, ratio)
        )
    }

    private func interpolate(_ lower: Double, _ upper: Double, _ ratio: Double) -> Double {
        lower + (upper - lower) * ratio
    }
}
