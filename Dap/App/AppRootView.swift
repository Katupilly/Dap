import SwiftUI

enum AppSection {
    case gallery
    case jam
}

struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: AppSection = .gallery
    @State private var isCapturePresented = false
    @State private var galleryPath: [UUID] = []
    @State private var library = PhotoLibraryViewModel()
    @State private var isJamSessionPresented = false
    @State private var createJamTrigger: UUID?

    private var isGalleryInspectorPresented: Bool {
        !galleryPath.isEmpty
    }

    private var showsSectionSwitcher: Bool {
        switch section {
        case .gallery:
            !isGalleryInspectorPresented
        case .jam:
            !isJamSessionPresented
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                GalleryView(library: library, path: $galleryPath)
                    .opacity(section == .gallery ? 1 : 0)
                    .allowsHitTesting(section == .gallery)
                    .accessibilityHidden(section != .gallery)

                JamLibraryView(
                    library: library,
                    isActive: section == .jam,
                    createJamTrigger: createJamTrigger,
                    onSessionPresentationChange: { isPresented in
                        isJamSessionPresented = isPresented
                    }
                )
                    .opacity(section == .jam ? 1 : 0)
                    .allowsHitTesting(section == .jam)
                    .accessibilityHidden(section != .jam)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if section == .gallery && !isGalleryInspectorPresented {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    ZStack {
                        Rectangle()
                            .fill(.regularMaterial)

                        Color.black.opacity(0.18)
                    }
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.30),
                                .init(color: .black.opacity(0.40), location: 0.60),
                                .init(color: .black.opacity(0.88), location: 0.86),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .frame(height: 80)
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }

            if section == .gallery && !isGalleryInspectorPresented {
                Button {
                    isCapturePresented = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 80, height: 80)
                        .glassEffect(
                            .regular
                                .tint(
                                    Color(
                                        red: 26 / 255,
                                        green: 26 / 255,
                                        blue: 30 / 255
                                    )
                                    .opacity(0.62)
                                )
                                .interactive(true),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .contentShape(
                    .interaction,
                    Circle().inset(by: -12)
                )
                .frame(maxWidth: .infinity)
                .padding(.bottom, 52)
                .accessibilityLabel("Open camera")
            }
        }
        .safeAreaInset(edge: .top) {
            if showsSectionSwitcher {
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
        .task {
            consumePendingActionIfNeeded()
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                consumePendingActionIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            consumePendingActionIfNeeded()
        }
        .statusBarHidden(true)
    }

    @MainActor
    private func consumePendingActionIfNeeded() {
        guard scenePhase == .active,
              let request = DapPendingActionStore.consume() else {
            return
        }

        switch request.action {
        case .openCapture:
            galleryPath.removeAll()
            section = .gallery
            isCapturePresented = true
        case .createJam:
            isCapturePresented = false
            galleryPath.removeAll()
            section = .jam
            createJamTrigger = request.id
        }
    }
}

private struct SectionSwitcher: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: AppSection
    @Namespace private var selectionBackground

    private var selectionAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.22, bounce: 0)
    }

    var body: some View {
        HStack(spacing: 4) {
            switchButton(.gallery, icon: "photo.stack.fill", title: "Gallery")
            switchButton(.jam, icon: "waveform", title: "Jam")
        }
        .padding(3)
        .frame(width: 192, height: 38)
        .background(Color(red: 26 / 255, green: 26 / 255, blue: 30 / 255), in: Capsule())
    }

    private func switchButton(_ section: AppSection, icon: String, title: String) -> some View {
        let isSelected = selection == section

        return Button {
            withAnimation(selectionAnimation) {
                selection = section
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))

                if isSelected {
                    Text(title)
                        .font(.custom("ZTTalk-Bold", size: 16,))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .opacity.combined(with: .offset(x: 4)),
                                    removal: .opacity
                                )
                        )
                }
            }
            .frame(width: isSelected ? 121 : 61, height: 32)
            .foregroundStyle(isSelected ? .black : .white)
            .background {
                if isSelected {
                    if reduceMotion {
                        Capsule()
                            .fill(.white)
                    } else {
                        Capsule()
                            .fill(.white)
                            .matchedGeometryEffect(id: "selectedSection", in: selectionBackground)
                    }
                }
            }
            .padding(.vertical, 6)
            .contentShape(.interaction, Rectangle())
            .padding(.vertical, -6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
