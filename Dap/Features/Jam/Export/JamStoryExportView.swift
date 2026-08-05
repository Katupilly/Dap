import SwiftUI
import UIKit

struct JamStoryExportLayout: Sendable {
    static let canvasSize = CGSize(width: 1080, height: 1920)
}

struct JamSnippetExportView: View {
    let snapshot: JamStoryExportSnapshot
    let coverImage: UIImage
    let photoImagesByID: [UUID: UIImage]
    let currentStep: Int?
    let pulse: CGFloat

    var body: some View {
        ZStack {
            jamBackground

            VStack(alignment: .leading, spacing: 0) {
                header

                Spacer(minLength: 54)

                artworkCard

                Spacer(minLength: 56)

                sequencer

                Spacer(minLength: 0)

                Text("MADE WITH DAP")
                    .font(.custom("ZTTalk-Bold", size: 22, relativeTo: .footnote))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.54))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 88)
            .padding(.top, 132)
            .padding(.bottom, 128)
        }
        .frame(width: JamStoryExportLayout.canvasSize.width, height: JamStoryExportLayout.canvasSize.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("DAP JAM")
                .font(.custom("ZTTalk-Bold", size: 28, relativeTo: .caption))
                .tracking(4.2)
                .foregroundStyle(.white.opacity(0.56))

            Text(snapshot.jamName)
                .font(.custom("ZTTalk-Bold", size: 86, relativeTo: .largeTitle))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.68)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                Text(regionDisplayName(snapshot.region).uppercased())
                    .font(.custom("ZTTalk-Bold", size: 24, relativeTo: .headline))
                    .tracking(1.6)

                Circle()
                    .fill(.white.opacity(0.42))
                    .frame(width: 7, height: 7)

                Text("\(snapshot.bpm) BPM")
                    .font(.custom("ZTTalk-Medium", size: 24, relativeTo: .headline))
            }
            .foregroundStyle(.white.opacity(0.74))
        }
    }

    private var artworkCard: some View {
        Group {
            if visiblePhotos.isEmpty {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 574)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            } else {
                HStack(spacing: 12) {
                    ForEach(visiblePhotos) { photo in
                        photoCrop(photo)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 574)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 46, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 46, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 2)
        }
        .shadow(
            color: artworkColor.opacity(0.22 + Double(artworkPulse) * 0.18),
            radius: 30 + artworkPulse * 12,
            y: 20
        )
        .scaleEffect(1 + artworkPulse * 0.012)
    }

    private func photoCrop(_ photo: JamStoryExportSnapshot.Photo) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(jamRGB: photo.accentColor).opacity(0.60),
                    Color(jamRGB: photo.accentColor).opacity(0.24)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image = photoImagesByID[photo.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 574)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var sequencer: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("JAM LOOP")
                    .font(.custom("ZTTalk-Bold", size: 24, relativeTo: .headline))
                    .tracking(1.8)

                Spacer(minLength: 0)

                Text("16 STEPS")
                    .font(.custom("ZTTalk-Medium", size: 21, relativeTo: .subheadline))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .foregroundStyle(.white)

            HStack(spacing: 8) {
                ForEach(0..<MusicSequence.steps, id: \.self) { step in
                    stepCell(step)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
        }
        .padding(28)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1.5)
        }
    }

    private var visiblePhotos: [JamStoryExportSnapshot.Photo] {
        Array(snapshot.photos.prefix(3))
    }

    private func stepCell(_ step: Int) -> some View {
        let roles = activeRoles(at: step)
        let isPlayhead = currentStep == step
        let isActive = !roles.isEmpty
        let color = Color(jamRGB: blendedColor(
            roles.compactMap { snapshot.roleColors[$0] },
            fallback: JamStoryExportSnapshot.fallbackAccent
        ))

        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isActive ? color.opacity(0.86) : .white.opacity(0.11))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .overlay {
                if isPlayhead {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.16 + Double(normalizedPulse) * 0.10))
                }
            }
            .overlay {
                if isPlayhead {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.92), lineWidth: 2)
                }
            }
            .shadow(
                color: isPlayhead ? .white.opacity(0.25 + Double(normalizedPulse) * 0.16) : .clear,
                radius: isPlayhead ? 7 : 0
            )
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
        .ignoresSafeArea()
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

    private var artworkColor: Color {
        Color(jamRGB: RetroCoverRenderer.tonalPalette(for: dominantPitch).highlight)
    }

    private var artworkPulse: CGFloat {
        guard pulse > 0,
              let currentStep,
              aggregatedSteps.contains(currentStep) else {
            return 0
        }
        return normalizedPulse
    }

    private var normalizedPulse: CGFloat {
        min(max(pulse, 0), 1)
    }

    private var aggregatedSteps: Set<Int> {
        Set(JamRole.allCases.flatMap { snapshot.sequencerSnapshot.steps(for: $0) })
    }

    private func activeRoles(at step: Int) -> [JamRole] {
        JamRole.allCases.filter { snapshot.sequencerSnapshot.steps(for: $0).contains(step) }
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
}
