import SwiftUI

enum AppSection {
    case gallery
    case jam
}

struct AppRootView: View {
    @State private var section: AppSection = .gallery
    @State private var isCapturePresented = false
    @State private var galleryPath: [UUID] = []
    @State private var library = PhotoLibraryViewModel()

    private var isGalleryInspectorPresented: Bool {
        !galleryPath.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                GalleryView(library: library, path: $galleryPath)
                    .opacity(section == .gallery ? 1 : 0)
                    .allowsHitTesting(section == .gallery)
                    .accessibilityHidden(section != .gallery)

                JamView()
                    .opacity(section == .jam ? 1 : 0)
                    .allowsHitTesting(section == .jam)
                    .accessibilityHidden(section != .jam)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !isGalleryInspectorPresented {
                Button {
                    isCapturePresented = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                }
                .buttonStyle(.plain)
                .padding(.leading, 24)
                .padding(.bottom, 52)
                .accessibilityLabel("Open camera")
            }
        }
        .safeAreaInset(edge: .top) {
            if !isGalleryInspectorPresented {
                SectionSwitcher(selection: $section)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
            }
        }
        .fullScreenCover(isPresented: $isCapturePresented) {
            CameraView(library: library)
        }
        .task {
            await library.loadLibrary()
        }
    }
}

private struct SectionSwitcher: View {
    @Binding var selection: AppSection

    var body: some View {
        HStack(spacing: 4) {
            switchButton(.gallery, icon: "music.note.list", title: "Gallery")
            switchButton(.jam, icon: "waveform", title: "Jam")
        }
        .padding(3)
        .frame(width: 169, height: 32)
        .background(.regularMaterial, in: Capsule())
        .animation(.snappy(duration: 0.22), value: selection)
    }

    private func switchButton(_ section: AppSection, icon: String, title: String) -> some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                if selection == section {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                }
            }
            .frame(maxWidth: selection == section ? .infinity : 40, maxHeight: .infinity)
            .foregroundStyle(.primary)
            .background(selection == section ? Color(uiColor: .secondarySystemBackground) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
