import SwiftUI

enum AppSection {
    case gallery
    case jam
}

struct AppRootView: View {
    @State private var section: AppSection = .gallery
    @State private var isCapturePresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Section", selection: $section) {
                    Text("Gallery").tag(AppSection.gallery)
                    Text("Jam").tag(AppSection.jam)
                }
                .pickerStyle(.segmented)

                Button {
                    isCapturePresented = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 34)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(.primary.opacity(0.1), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open camera")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            switch section {
            case .gallery:
                GalleryView()
            case .jam:
                JamView()
            }
        }
        .sheet(isPresented: $isCapturePresented) {
            CaptureView(isPresented: $isCapturePresented)
        }
    }
}
