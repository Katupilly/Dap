import SwiftUI
import UIKit

struct JamPanelBackdropPhoto {
    let role: JamRole
    let hasPhoto: Bool
    let image: UIImage?
    let noteLabel: String
    let accentColor: Color?
    let isActive: Bool
    let isSelected: Bool
}

struct JamPanelBackdropContent: View {
    let displayName: String
    let jamCoverImage: UIImage?
    let photos: [JamPanelBackdropPhoto]
    let hasAnySelection: Bool
    let hasSelectedSounds: Bool
    let playbackAction: PlaybackAction
    let canPlay: Bool
    let colorScheme: ColorScheme
    let reduceMotion: Bool

    private let bottomReserve: CGFloat = 168
    private let topHeaderInset: CGFloat = 18

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemBackground)

            ViewThatFits(in: .vertical) {
                fixedLayout
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                scrollingLayout
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
            }

            if hasAnySelection {
                playbackButtonVisual
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
    }

    private var fixedLayout: some View {
        VStack(spacing: 18) {
            header
            sessionBody
            Spacer(minLength: bottomReserve)
        }
        .padding(.top, topHeaderInset)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var scrollingLayout: some View {
        VStack(spacing: 18) {
            header
            sessionBody
        }
        .padding(.top, topHeaderInset)
        .padding(.horizontal, 20)
        .padding(.bottom, bottomReserve)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.secondary.opacity(0.12), in: Circle())

            headerCover

            Text(displayName)
                .font(.custom("ZTTalk-Bold", size: 22, relativeTo: .title2))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var headerCover: some View {
        if let jamCoverImage {
            Image(uiImage: jamCoverImage)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
        } else {
            Rectangle()
                .fill(fallbackHeaderCoverFill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }

    private var fallbackHeaderCoverFill: Color {
        photos.first(where: { $0.accentColor != nil })?.accentColor?.opacity(0.70) ?? .secondary.opacity(0.15)
    }

    @ViewBuilder
    private var sessionBody: some View {
        if hasAnySelection {
            Color.clear
                .frame(height: 150)
                .frame(maxWidth: .infinity)
        }

        if hasSelectedSounds {
            photoArea
        } else {
            emptyState
        }
    }

    private var photoArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ForEach(photos, id: \.role) { photo in
                    JamPanelBackdropPhotoTile(
                        photo: photo,
                        colorScheme: colorScheme,
                        reduceMotion: reduceMotion
                    )
                }
            }
            .frame(maxWidth: .infinity)

            changePhotosButtonVisual
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Choose one to three photos to shape the jam vibe.",
                systemImage: "waveform.path.ecg"
            )
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add Photos")
                    .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var changePhotosButtonVisual: some View {
        let backgroundFill: Color = colorScheme == .dark
            ? Color.secondary.opacity(0.12)
            : Color.black.opacity(0.08)
        let borderColor: Color = colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.10)

        return HStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .font(.system(size: 14, weight: .semibold))
            Text("Change Photos")
                .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .foregroundStyle(.primary)
        .background(backgroundFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
    }

    private var playbackButtonVisual: some View {
        HStack(spacing: 10) {
            Image(systemName: playbackAction.systemImage)
                .font(.headline.weight(.semibold))
            Text(playbackAction.title)
                .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(.white.opacity(canPlay ? 1 : 0.5))
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct JamPanelBackdropPhotoTile: View {
    let photo: JamPanelBackdropPhoto
    let colorScheme: ColorScheme
    let reduceMotion: Bool

    var body: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                photoContent
            }
            .overlay(alignment: .topLeading) {
                if photo.hasPhoto {
                    Text(photo.role.displayName)
                        .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.64), in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !photo.noteLabel.isEmpty {
                    Text(photo.noteLabel)
                        .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.64), in: Capsule())
                        .padding(6)
                }
            }
            .opacity(photo.hasPhoto ? 1 : 0.58)
            .frame(maxWidth: .infinity)
    }

    private var photoContent: some View {
        let style = JamTileVisualStyle(
            colorScheme: colorScheme,
            reduceMotion: reduceMotion,
            accentColor: photo.accentColor,
            hasRole: photo.hasPhoto,
            isSelected: photo.isSelected,
            isActive: photo.isActive
        )

        return image
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(color: style.shadowColor, radius: style.shadowRadius, y: style.shadowYOffset)
            .scaleEffect(style.baseScale)
            .offset(y: style.baseYOffset)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(style.selectionFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(style.contrastFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(style.borderColor, lineWidth: style.borderWidth)
            }
            .overlay {
                if style.haloOpacity > 0 {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(style.haloColor.opacity(style.haloOpacity), lineWidth: style.haloLineWidth)
                        .blur(radius: style.haloBlurRadius)
                }
            }
    }

    @ViewBuilder
    private var image: some View {
        GeometryReader { geometry in
            if let image = photo.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.18))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
        }
    }
}

