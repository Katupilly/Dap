import SwiftUI
import UIKit

struct JamStoryExportLayout: Sendable {
    static let canvasSize = CGSize(width: 1080, height: 1920)
    static let photosPanelFrame = CGRect(x: 38, y: 593, width: 1004, height: 426)
    static let signatureTop: CGFloat = 1749.75
    static let photoCornerRadius: CGFloat = 4
    static let panelCornerRadius: CGFloat = 8
    static let panelPadding: CGFloat = 20
    static let panelGap: CGFloat = 20
    static let sequencerPadding: CGFloat = 26
    static let sequencerHeaderSpacing: CGFloat = 18
    static let sequencerHeaderDetailSpacing: CGFloat = 4
    static let sequencerHeaderHeight: CGFloat = 54
    static let sequencerLabelWidth: CGFloat = 104
    static let sequencerLabelSpacing: CGFloat = 10
    static let sequencerStepSpacing: CGFloat = 5
    static let sequencerStepHeight: CGFloat = 18
    static let sequencerRowSpacing: CGFloat = 12
    static let sequencerGridHeight = 3 * sequencerStepHeight + 2 * sequencerRowSpacing
    static let sequencerContentHeight = 2 * sequencerPadding
        + sequencerHeaderHeight
        + sequencerHeaderSpacing
        + sequencerGridHeight
    static let sequencerFrame = CGRect(
        x: 38,
        y: 1059,
        width: 1004,
        height: sequencerContentHeight
    )
}

struct JamSnippetFrameState: Equatable, Sendable {
    let currentStep: Int?
    let stepProgress: Double
    let activeRoles: Set<JamRole>
    let pulseIntensity: Double

    init(
        currentStep: Int? = nil,
        stepProgress: Double = 0,
        activeRoles: Set<JamRole> = [],
        pulseIntensity: Double = 0
    ) {
        self.currentStep = currentStep
        self.stepProgress = min(max(stepProgress, 0), 1)
        self.activeRoles = activeRoles
        self.pulseIntensity = min(max(pulseIntensity, 0), 1)
    }
}

struct JamSnippetExportView: View {
    let snapshot: JamStoryExportSnapshot
    let photoImagesByID: [UUID: UIImage]
    let frameState: JamSnippetFrameState

    init(
        snapshot: JamStoryExportSnapshot,
        photoImagesByID: [UUID: UIImage],
        frameState: JamSnippetFrameState
    ) {
        self.snapshot = snapshot
        self.photoImagesByID = photoImagesByID
        self.frameState = frameState
    }

    init(
        snapshot: JamStoryExportSnapshot,
        photoImagesByID: [UUID: UIImage],
        currentStep: Int? = nil,
        pulse: CGFloat = 0
    ) {
        let activeRoles = currentStep.map { step in
            Set(JamRole.allCases.filter { snapshot.sequencerSnapshot.steps(for: $0).contains(step) })
        } ?? []
        self.init(
            snapshot: snapshot,
            photoImagesByID: photoImagesByID,
            frameState: JamSnippetFrameState(
                currentStep: currentStep,
                activeRoles: activeRoles,
                pulseIntensity: Double(pulse)
            )
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            jamBackground
                .frame(width: JamStoryExportLayout.canvasSize.width, height: JamStoryExportLayout.canvasSize.height)

            Text("DAP JAM")
                .font(.custom("ZTTalk-Medium", size: 24))
                .foregroundStyle(headerForeground.secondary)
                .frame(width: JamStoryExportLayout.canvasSize.width, alignment: .center)
                .padding(.top, 449.98)

            Text(snapshot.jamName)
                .font(.custom("ZTTalk-Medium", size: 48))
                .foregroundStyle(headerForeground.primary)
                .frame(width: 840, alignment: .center)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 480.98)

            photosPanel
                .padding(.top, JamStoryExportLayout.photosPanelFrame.minY)

            sequencer
                .padding(.top, JamStoryExportLayout.sequencerFrame.minY)

            Text("Made with Dap")
                .font(.custom("ZTTalk-SemiBold", size: 24))
                .foregroundStyle(signatureForeground.secondary)
                .frame(width: JamStoryExportLayout.canvasSize.width, alignment: .center)
                .padding(.top, JamStoryExportLayout.signatureTop)
        }
        .frame(width: JamStoryExportLayout.canvasSize.width, height: JamStoryExportLayout.canvasSize.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private var photosPanel: some View {
        HStack(spacing: JamStoryExportLayout.panelGap) {
            ForEach(visiblePhotos) { photo in
                photoCrop(photo)
            }
        }
        .padding(JamStoryExportLayout.panelPadding)
        .frame(
            width: JamStoryExportLayout.photosPanelFrame.width,
            height: JamStoryExportLayout.photosPanelFrame.height,
            alignment: .topLeading
        )
        .background(Color(jamRGB: RGBColor(red: 26, green: 26, blue: 30)))
        .clipShape(
            RoundedRectangle(
                cornerRadius: JamStoryExportLayout.panelCornerRadius,
                style: .continuous
            )
        )
        .clipped()
    }

    private func photoCrop(_ photo: JamStoryExportSnapshot.Photo) -> some View {
        let photoWidth = photoWidth(for: visiblePhotos.count)
        let isActive = photo.role.map(frameState.activeRoles.contains) == true
        let pulse = isActive ? frameState.pulseIntensity : 0

        return ZStack {
            Color(jamRGB: photo.accentColor).opacity(0.34)

            if let image = photoImagesByID[photo.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .modifier(PhotoPaperTextureModifier())
        .frame(width: photoWidth, height: 386)
        .clipShape(
            RoundedRectangle(
                cornerRadius: JamStoryExportLayout.photoCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: JamStoryExportLayout.photoCornerRadius,
                style: .continuous
            )
                .stroke(
                    Color(jamRGB: photo.accentColor).opacity(0.26 + pulse * 0.48),
                    lineWidth: 1.5 + pulse * 1.5
                )
        }
        .shadow(
            color: Color(jamRGB: photo.accentColor).opacity(pulse * 0.45),
            radius: 6 + pulse * 10
        )
        .scaleEffect(1 + pulse * 0.008)
    }

    private var sequencer: some View {
        VStack(alignment: .leading, spacing: JamStoryExportLayout.sequencerHeaderSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: JamStoryExportLayout.sequencerHeaderDetailSpacing) {
                    Text(regionDisplayName(snapshot.region).uppercased())
                        .font(.custom("ZTTalk-Bold", size: 22, relativeTo: .headline))
                        .tracking(1.4)
                        .foregroundStyle(.white)

                    Text("\(drumKitDisplayName(snapshot.drumKit)) kit · \(snapshot.bpm) BPM")
                        .font(.custom("ZTTalk-Medium", size: 22, relativeTo: .subheadline))
                        .foregroundStyle(.white.opacity(0.58))
                }

                Spacer(minLength: 0)
            }
            .frame(height: JamStoryExportLayout.sequencerHeaderHeight, alignment: .topLeading)

            JamStorySequencerGrid(
                snapshot: snapshot.sequencerSnapshot,
                roleColors: snapshot.roleColors,
                currentStep: frameState.currentStep,
                stepProgress: frameState.stepProgress,
                pulseIntensity: frameState.pulseIntensity
            )
        }
        .padding(JamStoryExportLayout.sequencerPadding)
        .frame(
            width: JamStoryExportLayout.sequencerFrame.width,
            height: JamStoryExportLayout.sequencerFrame.height,
            alignment: .center
        )
        .background(Color(jamRGB: RGBColor(red: 26, green: 26, blue: 30)))
        .clipShape(
            RoundedRectangle(
                cornerRadius: JamStoryExportLayout.panelCornerRadius,
                style: .continuous
            )
        )
        .clipped()
    }

    private var visiblePhotos: [JamStoryExportSnapshot.Photo] {
        Array(snapshot.photos.prefix(3))
    }

    private func photoWidth(for count: Int) -> CGFloat {
        let count = max(1, min(3, count))
        let available = JamStoryExportLayout.photosPanelFrame.width
            - 2 * JamStoryExportLayout.panelPadding
            - CGFloat(count - 1) * JamStoryExportLayout.panelGap
        return available / CGFloat(count)
    }

    private var jamBackground: some View {
        let colors = backgroundColors

        return ZStack {
            LinearGradient(
                colors: [colors.shadow, colors.dark, colors.base],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(colors.highlight.opacity(0.22))
                .frame(width: 820, height: 820)
                .blur(radius: 110)
                .offset(x: 340, y: -690)

            Circle()
                .fill(colors.base.opacity(0.25))
                .frame(width: 900, height: 900)
                .blur(radius: 130)
                .offset(x: -420, y: 620)

            LinearGradient(
                colors: [.black.opacity(0.08), .black.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .modifier(PhotoPaperTextureModifier())
    }

    private var backgroundColors: (shadow: Color, dark: Color, base: Color, highlight: Color) {
        let palette = RetroCoverRenderer.tonalPalette(for: dominantPitch)
        let accents = JamRole.allCases.compactMap { snapshot.roleColors[$0] }
        let blendedAccent = blendedColor(accents, fallback: palette.base)

        return (
            Color(jamRGB: palette.shadow).opacity(0.98),
            Color(jamRGB: blendedAccent).opacity(0.72),
            Color(jamRGB: palette.base).opacity(0.76),
            Color(jamRGB: palette.highlight)
        )
    }

    private var contrastGradient: PhotoStoryBackgroundGradient {
        let palette = RetroCoverRenderer.tonalPalette(for: dominantPitch)
        let accents = JamRole.allCases.compactMap { snapshot.roleColors[$0] }
        let blendedAccent = blendedColor(accents, fallback: palette.base)
        return PhotoStoryBackgroundGradient(
            palette: ColorPalette(
                shadow: palette.shadow,
                dark: blendedAccent,
                base: palette.base,
                highlight: palette.highlight
            )
        )
    }

    private var headerForeground: AdaptiveStoryForeground {
        foregroundColors(
            atNormalizedY: (449.98 + 480.98) / 2 / JamStoryExportLayout.canvasSize.height,
            gradient: contrastGradient
        )
    }

    private var signatureForeground: AdaptiveStoryForeground {
        foregroundColors(
            atNormalizedY: (JamStoryExportLayout.signatureTop + 24) / JamStoryExportLayout.canvasSize.height,
            gradient: contrastGradient
        )
    }

    private var dominantPitch: PitchClass {
        if let bass = snapshot.coverDescriptor.bassPitch { return bass }
        if let harmony = snapshot.coverDescriptor.harmonyPitch { return harmony }
        if let melody = snapshot.coverDescriptor.melodyPitch { return melody }
        return snapshot.coverDescriptor.reservePitches.first ?? .c
    }

    private func blendedColor(_ colors: [RGBColor], fallback: RGBColor) -> RGBColor {
        guard !colors.isEmpty else { return fallback }
        let red = colors.reduce(0) { $0 + Int($1.red) } / colors.count
        let green = colors.reduce(0) { $0 + Int($1.green) } / colors.count
        let blue = colors.reduce(0) { $0 + Int($1.blue) } / colors.count
        return RGBColor(red: UInt8(red), green: UInt8(green), blue: UInt8(blue))
    }

    private func regionDisplayName(_ region: JamRegion) -> String {
        switch region {
        case .airy: "Airy"
        case .bright: "Bright"
        case .deep: "Deep"
        case .intense: "Intense"
        }
    }

    private func drumKitDisplayName(_ kit: MusicDrumKit) -> String {
        switch kit {
        case .soft: "Soft"
        case .club: "Club"
        case .breakbeat: "Break"
        case .metal: "Metal"
        }
    }
}

private struct JamStorySequencerGrid: View {
    let snapshot: JamSequencerSnapshot
    let roleColors: [JamRole: RGBColor]
    let currentStep: Int?
    let stepProgress: Double
    let pulseIntensity: Double

    private static let roles: [JamRole] = [.bass, .harmony, .melody]

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: JamStoryExportLayout.sequencerRowSpacing) {
                ForEach(Self.roles, id: \.self) { role in
                    row(for: role)
                }
            }

            if let currentStep {
                playhead(currentStep: currentStep)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for role: JamRole) -> some View {
        let activeSteps = snapshot.steps(for: role)
        let color = Color(jamRGB: roleColors[role] ?? JamStoryExportSnapshot.fallbackAccent)

        return HStack(spacing: JamStoryExportLayout.sequencerLabelSpacing) {
            Text(role.displayName.uppercased())
                .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .caption))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.56))
                .frame(width: JamStoryExportLayout.sequencerLabelWidth, alignment: .leading)

            HStack(spacing: JamStoryExportLayout.sequencerStepSpacing) {
                ForEach(0..<MusicSequence.steps, id: \.self) { step in
                    stepCell(
                        color: color,
                        isActive: activeSteps.contains(step)
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func stepCell(
        color: Color,
        isActive: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isActive ? color.opacity(0.86) : color.opacity(0.18))
            .frame(maxWidth: .infinity)
            .frame(height: JamStoryExportLayout.sequencerStepHeight)
    }

    private func playhead(currentStep: Int) -> some View {
        GeometryReader { proxy in
            let gridX = JamStoryExportLayout.sequencerLabelWidth
                + JamStoryExportLayout.sequencerLabelSpacing
            let gridWidth = proxy.size.width - gridX
            let stepWidth = (
                gridWidth
                    - CGFloat(MusicSequence.steps - 1) * JamStoryExportLayout.sequencerStepSpacing
            ) / CGFloat(MusicSequence.steps)
            let stepOffset = CGFloat(currentStep) + CGFloat(stepProgress)
            let unclampedCenterX = gridX
                + stepOffset * (stepWidth + JamStoryExportLayout.sequencerStepSpacing)
                + stepWidth / 2
            let centerX = min(
                max(unclampedCenterX, gridX + stepWidth / 2),
                gridX + gridWidth - stepWidth / 2
            )

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.10 + pulseIntensity * 0.10))
                    .frame(width: max(stepWidth - 8, 0), height: proxy.size.height)
                    .position(x: centerX, y: proxy.size.height / 2)

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white.opacity(0.58 + pulseIntensity * 0.26))
                    .frame(width: 6, height: proxy.size.height)
                    .position(x: centerX, y: proxy.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}
