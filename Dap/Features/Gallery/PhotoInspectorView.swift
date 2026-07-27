import SwiftUI
import CoreTransferable
import UIKit
import UniformTypeIdentifiers

struct PhotoInspectorView: View {
    private static let coverFrameSize = CGSize(
        width: 361,
        height: 429.6994934082031
    )
    private static let coverAspectRatio =
        coverFrameSize.width / coverFrameSize.height

    let sound: PhotoSound
    let coverData: Data?
    let library: PhotoLibraryViewModel
    let namespace: Namespace.ID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingDeleteError = false
    @State private var isDeleting = false

    private var rootPitch: PitchClass {
        PitchClass(rawValue: sound.sequence.harmony.rootPitchClass) ?? .c
    }

    private var rootRGB: RGBColor {
        RetroCoverRenderer.tonalPalette(for: rootPitch).base
    }

    private var rootColor: Color {
        Color(rootRGB)
    }

    private var foreground: Color {
        rootRGB.luminance / 255 > 0.62 ? .black : .white
    }

    private var secondaryForeground: Color {
        foreground.opacity(0.48)
    }

    private var isPlaying: Bool {
        library.playingID == sound.id
    }

    private var coverUIImage: UIImage? {
        guard let coverData else { return nil }
        return UIImage(data: coverData)
    }

    private var sharePreview: SharePreview<Data, Never>? {
        guard let coverData else { return nil }
        return SharePreview(
            sound.name ?? sound.sequence.displayLabel,
            image: coverData
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                cover

                VStack(spacing: 8) {
                    Text(sound.name ?? sound.sequence.displayLabel)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(foreground)

                    if let description = sound.description, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(secondaryForeground)
                            .padding(.horizontal, 22)
                    }

                    musicInfo
                        .padding(.top, 4)
                }

                Spacer(minLength: 220)
            }
            .padding(.top, 22)
            .padding(.bottom, 150)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(rootColor.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            bottomControls
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle("Photo Inspector")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let coverData, let sharePreview {
                        ShareLink(
                            item: CoverImageExport(data: coverData),
                            preview: sharePreview
                        ) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .disabled(true)
                    }

                    Button {
                    } label: {
                        Label("Add to Jam", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(true)

                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label("Delete Photo", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .disabled(isDeleting)
                .accessibilityLabel("Photo options")
            }
        }
        .confirmationDialog("Delete Photo?", isPresented: $isShowingDeleteConfirmation) {
            Button("Delete Photo", role: .destructive, action: deletePhoto)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Couldn't Delete Photo", isPresented: $isShowingDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again.")
        }
        .conditionalZoom(!reduceMotion, sourceID: sound.id, namespace: namespace)
    }

    private var cover: some View {
        Color.clear
            .aspectRatio(Self.coverAspectRatio, contentMode: .fit)
            .overlay {
                coverImage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .frame(maxWidth: Self.coverFrameSize.width)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
    }

    private var musicInfo: some View {
        HStack(spacing: 24) {
            infoColumn(icon: "music.note", label: "Root", value: rootPitch.symbol)
            infoColumn(icon: "scale.3d", label: "Scale", value: sound.sequence.harmony.scale.displayName)
            infoColumn(icon: "metronome", label: "BPM", value: "\(sound.sequence.harmony.bpm)")
        }
        .font(.footnote)
        .foregroundStyle(secondaryForeground)
    }

    private var bottomControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    library.toggle(sound: sound)
                } label: {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(InspectorButtonStyle(background: .white.opacity(0.9), foreground: .black))

                Button {} label: {
                    Label("Add Effects", systemImage: "staroflife.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(InspectorButtonStyle(background: .white.opacity(0.9), foreground: .black))
                .disabled(true)
            }
        }
        .font(.footnote.weight(.semibold))
        .padding(.horizontal, 48.5)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .disabled(isDeleting)
    }

    private func infoColumn(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Label(label, systemImage: icon)
                .labelStyle(.titleAndIcon)
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: 76)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let image = coverUIImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(foreground.opacity(0.16))
        }
    }

    private func deletePhoto() {
        guard !isDeleting else { return }

        isDeleting = true

        Task {
            do {
                try await library.delete(sound: sound)
                isDeleting = false
                dismiss()
            } catch {
                isDeleting = false
                isShowingDeleteError = true
            }
        }
    }
}

private struct CoverImageExport: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { export in
            export.data
        }
    }
}

private struct InspectorButtonStyle: ButtonStyle {
    let background: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .foregroundStyle(foreground)
            .background(background.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func conditionalZoom(_ enabled: Bool, sourceID: UUID, namespace: Namespace.ID) -> some View {
        if enabled {
            navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }
}

private extension Color {
    init(_ rgb: RGBColor) {
        self.init(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}
