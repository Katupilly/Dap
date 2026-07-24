import SwiftUI
import UIKit

struct GalleryView: View {
    let library: PhotoLibraryViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        NavigationStack {
            if library.items.isEmpty {
                ContentUnavailableView(
                    "No Photos Yet",
                    systemImage: "photo.stack",
                    description: Text("Musical photos you create will appear here.")
                )
                .navigationTitle("Gallery")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(library.items) { sound in
                            SoundCellView(
                                sound: sound,
                                coverData: library.coverDataByID[sound.id],
                                isPlaying: library.playingID == sound.id,
                                isRefining: library.refiningMetadataIDs.contains(sound.id)
                            )
                            .onTapGesture {
                                library.toggle(sound: sound)
                            }
                        }
                    }
                }
                .navigationTitle("Gallery")
            }
        }
    }
}

// MARK: - Sound Cell

private struct SoundCellView: View {
    let sound: PhotoSound
    let coverData: Data?
    let isPlaying: Bool
    let isRefining: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            coverImage
                .aspectRatio(1, contentMode: .fill)
                .clipped()

            VStack(alignment: .leading, spacing: 1) {
                // Primary title: generated name when available, musical fallback otherwise.
                Text(sound.name ?? sound.sequence.displayLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // Secondary: note/scale always visible, BPM below it.
                if sound.name != nil {
                    Text(sound.sequence.displayLabel)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                Text("\(sound.sequence.harmony.bpm) BPM")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.5))

            // Discreet refinement indicator — top-leading corner.
            if isRefining {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(.white)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay {
            if isPlaying {
                Rectangle()
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
