import SwiftUI
import UIKit

struct JamStoryExportView: View {
    let snapshot: JamStoryExportSnapshot
    let coverImage: UIImage
    let photoImagesByID: [UUID: UIImage]

    private let safeTop: CGFloat = 180
    private let safeBottom: CGFloat = 190
    private let horizontalInset: CGFloat = 82

    var body: some View {
        ZStack {
            storyBackground

            VStack(alignment: .leading, spacing: 34) {
                titleBlock

                coverBlock

                photoTiles

                sequencerBlock


                Spacer(minLength: 0)

                signature
            }
            .padding(.top, safeTop)
            .padding(.bottom, safeBottom)
            .padding(.horizontal, horizontalInset)
        }
        .frame(width: JamStoryRenderer.outputPixelSize.width, height: JamStoryRenderer.outputPixelSize.height)
        .environment(\.colorScheme, .dark)
    }

    private var storyBackground: some View {
        let colors = backgroundColors

        return ZStack {
            LinearGradient(
                colors: [colors.shadow, colors.dark, colors.base],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(colors.highlight.opacity(0.20))
                .frame(width: 720, height: 720)
                .blur(radius: 90)
                .offset(x: 310, y: -600)

            Circle()
                .fill(colors.base.opacity(0.28))
                .frame(width: 760, height: 760)
                .blur(radius: 110)
                .offset(x: -360, y: 420)

            LinearGradient(
                colors: [.black.opacity(0.10), .black.opacity(0.34)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("DAP JAM")
                .font(.custom("ZTTalk-Bold", size: 24, relativeTo: .caption))
                .tracking(3.8)
                .foregroundStyle(.white.opacity(0.52))

            Text(snapshot.jamName)
                .font(.custom("ZTTalk-Bold", size: 82, relativeTo: .largeTitle))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var coverBlock: some View {
        Image(uiImage: coverImage)
            .resizable()
            .scaledToFill()
            .frame(width: 668, height: 668)
            .clipShape(RoundedRectangle(cornerRadius: 42, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 42, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.34), radius: 48, y: 30)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
    }

    private var photoTiles: some View {
        HStack(spacing: 18) {
            ForEach(snapshot.photos) { photo in
                JamStoryPhotoTile(
                    photo: photo,
                    image: photoImagesByID[photo.id]
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sequencerBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
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

            JamStorySequencerGrid(
                snapshot: snapshot.sequencerSnapshot,
                roleColors: snapshot.roleColors
            )
        }
        .padding(26)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1.5)
        }
    }

    private var signature: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.white.opacity(0.86))
                .frame(width: 9, height: 9)

            Text("Made with Dap")
                .font(.custom("ZTTalk-Bold", size: 24, relativeTo: .footnote))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var backgroundColors: (shadow: Color, dark: Color, base: Color, highlight: Color) {
        let accents = snapshot.roleColors.values
        let first = accents.first ?? JamStoryExportSnapshot.fallbackAccent
        let base = blendedColor(Array(accents), fallback: first)
        let palette = RetroCoverRenderer.tonalPalette(for: dominantPitch)
        return (
            Color(jamRGB: palette.shadow).opacity(0.98),
            Color(jamRGB: first).opacity(0.78),
            Color(jamRGB: base).opacity(0.82),
            Color(jamRGB: palette.highlight)
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

private struct JamStoryPhotoTile: View {
    let photo: JamStoryExportSnapshot.Photo
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                fallbackFill

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 210, height: 252)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .topLeading) {
                if let role = photo.role {
                    Text(role.displayName.uppercased())
                        .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .caption))
                        .tracking(0.9)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.54), in: Capsule())
                        .padding(12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Text(photo.noteLabel)
                    .font(.custom("ZTTalk-Bold", size: 18, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.54), in: Capsule())
                    .padding(12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color(jamRGB: photo.accentColor).opacity(0.66), lineWidth: 2)
            }

            Text(photo.title)
                .font(.custom("ZTTalk-Bold", size: 20, relativeTo: .caption))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
                .frame(width: 210, alignment: .leading)
        }
    }

    private var fallbackFill: some View {
        LinearGradient(
            colors: [
                Color(jamRGB: photo.accentColor).opacity(0.42),
                .black.opacity(0.20),
                Color(jamRGB: photo.accentColor).opacity(0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "photo")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.26))
        }
    }
}

private struct JamStorySequencerGrid: View {
    let snapshot: JamSequencerSnapshot
    let roleColors: [JamRole: RGBColor]

    private static let roles: [JamRole] = [.bass, .harmony, .melody]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Self.roles, id: \.self) { role in
                row(for: role)
            }
        }
    }

    private func row(for role: JamRole) -> some View {
        let activeSteps = snapshot.steps(for: role)
        let color = Color(jamRGB: roleColors[role] ?? JamStoryExportSnapshot.fallbackAccent)

        return HStack(spacing: 10) {
            Text(role.displayName.uppercased())
                .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .caption))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.56))
                .frame(width: 104, alignment: .leading)

            HStack(spacing: 5) {
                ForEach(0..<MusicSequence.steps, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(activeSteps.contains(step) ? color.opacity(0.86) : color.opacity(0.18))
                        .frame(maxWidth: .infinity)
                        .frame(height: 18)
                }
            }
        }
    }
}
