import SwiftUI
import UIKit

struct GalleryView: View {
    let library: PhotoLibraryViewModel
    @Binding var path: [UUID]

    @Namespace private var namespace

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        NavigationStack(path: $path) {
            if library.items.isEmpty {
                ContentUnavailableView(
                    "No Photos Yet",
                    systemImage: "photo.stack",
                    description: Text("Musical photos you create will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.galleryBackground)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(library.items) { sound in
                            Button {
                                path.append(sound.id)
                            } label: {
                                SoundCellView(
                                    sound: sound,
                                    coverData: library.coverDataByID[sound.id],
                                    isPlaying: library.playingID == sound.id,
                                    isRefining: library.refiningMetadataIDs.contains(sound.id),
                                    namespace: namespace
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 84)
                    .padding(.bottom, 120)
                }
                .background(Color.galleryBackground)
                .navigationDestination(for: UUID.self) { id in
                    if let sound = library.items.first(where: { $0.id == id }) {
                        PhotoInspectorView(
                            sound: sound,
                            coverData: library.coverDataByID[id],
                            library: library,
                            namespace: namespace
                        )
                    }
                }
            }
        }
        .background(Color.galleryBackground)
    }
}

// MARK: - Sound Cell

private struct SoundCellView: View {
    let sound: PhotoSound
    let coverData: Data?
    let isPlaying: Bool
    let isRefining: Bool
    let namespace: Namespace.ID

    var body: some View {
        ZStack(alignment: .topLeading) {
            coverImage
                .aspectRatio(4 / 5, contentMode: .fill)
                .clipped()
                .matchedTransitionSource(id: sound.id, in: namespace)

            if isRefining {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(.white)
                    .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            if isPlaying {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.white, lineWidth: 2)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "waveform")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(4)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isPlaying)
        .accessibilityLabel(sound.name ?? sound.sequence.displayLabel)
        .accessibilityHint("Opens the Photo Inspector.")
    }

    @ViewBuilder
    private var coverImage: some View {
        // Data is already in memory from library.coverDataByID — no disk I/O here.
        if let data = coverData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
        } else {
            Rectangle()
                .fill(.secondary.opacity(0.18))
        }
    }
}

private extension Color {
    static let galleryBackground = Color(uiColor: .systemBackground)
}
