import SwiftUI
import UIKit

struct GalleryView: View {
    let library: PhotoLibraryViewModel
    @Binding var path: [UUID]
    @Binding var isGallerySelecting: Bool
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedPhotoIDs = Set<UUID>()
    @State private var isPreparingShare = false
    @State private var sharePresentation: GallerySharePresentation?
    @State private var shareErrorMessage: String?
    @State private var isShowingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?
    @State private var deletionFeedbackToken = 0
    @State private var jamAdditionFeedbackToken = 0
    @State private var isShowingJamPicker = false
    @State private var isShowingJamPhotoChooser = false
    @State private var pendingJamPhotos: [PhotoSound]?
    @State private var jamPhotos: [PhotoSound] = []

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]
    private var orderedSelectedSounds: [PhotoSound] {
        library.items.filter { selectedPhotoIDs.contains($0.id) }
    }

    private var selectionCount: Int {
        orderedSelectedSounds.count
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                galleryContent

                edgeBlurOverlays

                if isGallerySelecting && path.isEmpty {
                    topHeader
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isGallerySelecting && path.isEmpty {
                    selectionBottomBar
                }
            }
            .background(Color.galleryBackground)
            .navigationDestination(for: UUID.self) { id in
                if let sound = library.items.first(where: { $0.id == id }) {
                    PhotoInspectorView(
                        sound: sound,
                        coverData: library.coverDataByID[id],
                        library: library
                    )
                }
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: isGallerySelecting
        )
        .background(Color.galleryBackground)
        .onChange(of: library.items.map(\.id)) { _, newIDs in
            selectedPhotoIDs.formIntersection(Set(newIDs))
        }
        .onChange(of: isGallerySelecting) { _, isSelecting in
            if !isSelecting {
                selectedPhotoIDs.removeAll()
            }
        }
        .onChange(of: isActive) { _, active in
            if !active {
                exitSelection()
            }
        }
        .sensoryFeedback(.selection, trigger: selectedPhotoIDs)
        .sensoryFeedback(.success, trigger: deletionFeedbackToken)
        .sensoryFeedback(.success, trigger: jamAdditionFeedbackToken)
        .alert("Couldn't Share Photos", isPresented: shareErrorPresented) {
            Button("OK", role: .cancel) {
                shareErrorMessage = nil
            }
        } message: {
            Text(shareErrorMessage ?? "Try again.")
        }
        .alert("Couldn't Delete All Photos", isPresented: deleteErrorPresented) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "Try again.")
        }
        .alert(deleteConfirmationTitle, isPresented: $isShowingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}

            Button("Delete", role: .destructive) {
                deleteSelectedPhotos()
            }
        } message: {
            Text("This action can’t be undone.")
        }
        .sheet(item: $sharePresentation) { presentation in
            GalleryActivityViewController(activityItems: presentation.urls) {
                DapExportFileHelper.removeTemporaryExports()
            }
        }
        .sheet(isPresented: $isShowingJamPicker) {
            AddToJamSheet(
                library: library,
                photos: jamPhotos,
                isPresented: $isShowingJamPicker,
                onAdded: handleJamAdded
            )
        }
        .sheet(
            isPresented: $isShowingJamPhotoChooser,
            onDismiss: presentJamPickerAfterPhotoChoice
        ) {
            ChooseJamPhotosSheet(
                library: library,
                photos: orderedSelectedSounds
            ) { selectedPhotos in
                pendingJamPhotos = selectedPhotos
                isShowingJamPhotoChooser = false
            }
        }
    }

    private var edgeBlurOverlays: some View {
        Group {
            if isActive && path.isEmpty {
                DapEdgeBlur(edge: .top)
                    .frame(maxWidth: .infinity)
                    .frame(height: DapEdgeBlur.topHeight)
                    .offset(y: -DapEdgeBlur.edgeExtension)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)

                DapEdgeBlur(edge: .bottom)
                    .frame(maxWidth: .infinity)
                    .frame(height: DapEdgeBlur.bottomHeight)
                    .offset(y: DapEdgeBlur.edgeExtension)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var galleryContent: some View {
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
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(library.items) { sound in
                        Button {
                            handleCellTap(for: sound.id)
                        } label: {
                            SoundCellView(
                                sound: sound,
                                coverData: library.coverDataByID[sound.id],
                                isPlaying: library.playingID == sound.id,
                                isRefining: library.refiningMetadataIDs.contains(sound.id),
                                isSelecting: isGallerySelecting,
                                isSelected: selectedPhotoIDs.contains(sound.id),
                                reduceMotion: reduceMotion
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparingShare || isDeleting)
                        .accessibilityAction(named: "Select photo") {
                            beginSelection(with: sound.id)
                        }
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.5)
                                .onEnded { _ in
                                    beginSelection(with: sound.id)
                                }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 84)
                .padding(.bottom, 120)
            }
        }
    }

    private var topHeader: some View {
        Text("\(selectionCount) selected")
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.top, 16)
    }

    private var selectionBottomBar: some View {
        GlassEffectContainer(spacing: 18) {
            HStack {
                Button {
                    prepareBatchShare()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(StoryHeaderGlassButtonStyle())
                .disabled(selectionCount == 0 || isPreparingShare || isDeleting)
                .accessibilityLabel(shareAccessibilityLabel)

                Spacer()

                Button {
                    beginAddToJam()
                } label: {
                    Label(
                        "Add to Jam",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                }
                .buttonStyle(GalleryAddToJamButtonStyle())
                .disabled(selectionCount == 0 || isPreparingShare || isDeleting)
                .accessibilityLabel(addToJamAccessibilityLabel)

                Spacer()

                Button {
                    isShowingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(StoryHeaderGlassButtonStyle())
                .disabled(selectionCount == 0 || isPreparingShare || isDeleting)
                .accessibilityLabel(deleteAccessibilityLabel)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private var shareErrorPresented: Binding<Bool> {
        Binding(
            get: { shareErrorMessage != nil },
            set: { if !$0 { shareErrorMessage = nil } }
        )
    }

    private var deleteErrorPresented: Binding<Bool> {
        Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )
    }

    private var deleteConfirmationTitle: String {
        selectionCount == 1 ? "Delete Photo?" : "Delete \(selectionCount) Photos?"
    }

    private var shareAccessibilityLabel: String {
        selectionCount == 1 ? "Share 1 Photo" : "Share \(selectionCount) Photos"
    }

    private var deleteAccessibilityLabel: String {
        selectionCount == 1 ? "Delete 1 Photo" : "Delete \(selectionCount) Photos"
    }

    private var addToJamAccessibilityLabel: String {
        selectionCount == 1 ? "Add 1 Photo to Jam" : "Add \(selectionCount) Photos to Jam"
    }

    private func beginSelection(with id: UUID) {
        guard library.items.contains(where: { $0.id == id }) else { return }
        isGallerySelecting = true
        selectedPhotoIDs.insert(id)
    }

    private func exitSelection() {
        selectedPhotoIDs.removeAll()
        isGallerySelecting = false
    }

    private func handleCellTap(for id: UUID) {
        guard !isPreparingShare, !isDeleting else { return }

        if isGallerySelecting {
            if selectedPhotoIDs.contains(id) {
                selectedPhotoIDs.remove(id)
            } else {
                selectedPhotoIDs.insert(id)
            }
        } else {
            path.append(id)
        }
    }

    private func prepareBatchShare() {
        guard !isPreparingShare, !orderedSelectedSounds.isEmpty else { return }

        isPreparingShare = true
        shareErrorMessage = nil
        let sounds = orderedSelectedSounds

        Task { @MainActor in
            do {
                let renderer = PhotoExportRenderer()
                var imageData: [Data] = []
                imageData.reserveCapacity(sounds.count)

                for sound in sounds {
                    guard let snapshot = PhotoStoryExportSnapshot(
                        sound: sound,
                        coverData: library.coverDataByID[sound.id]
                    ) else {
                        throw GalleryShareError.missingCover(sound.displayTitle)
                    }

                    let result = try await renderer.render(
                        template: .plain,
                        snapshot: snapshot
                    )
                    imageData.append(result.pngData)
                }

                let urls = try DapExportFileHelper.preparePhotos(data: imageData)
                guard urls.count == sounds.count else {
                    throw GalleryShareError.incompletePreparation
                }

                sharePresentation = GallerySharePresentation(urls: urls)
            } catch is CancellationError {
                DapExportFileHelper.removeTemporaryExports()
            } catch {
                DapExportFileHelper.removeTemporaryExports()
                shareErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Could not prepare the selected photos."
            }

            isPreparingShare = false
        }
    }

    private func deleteSelectedPhotos() {
        guard !isDeleting else { return }

        let requestedIDs = orderedSelectedSounds.map(\.id)
        guard !requestedIDs.isEmpty else { return }

        isDeleting = true

        Task { @MainActor in
            let result = await library.delete(ids: requestedIDs)
            selectedPhotoIDs = Set(result.remainingIDs)
            isDeleting = false

            if result.didRemoveAllExistingPhotos {
                deletionFeedbackToken += 1
                isGallerySelecting = false
            } else {
                deleteErrorMessage = deletionMessage(for: result)
            }
        }
    }

    private func handleJamAdded() {
        jamAdditionFeedbackToken += 1
        UIAccessibility.post(
            notification: .announcement,
            argument: selectionCount == 1
                ? "Added 1 Photo to Jam"
                : "Added \(selectionCount) Photos to Jam"
        )
        selectedPhotoIDs.removeAll()
        jamPhotos.removeAll()
        isGallerySelecting = false
    }

    private func beginAddToJam() {
        let selectedPhotos = orderedSelectedSounds
        guard !selectedPhotos.isEmpty else { return }

        if selectedPhotos.count > JamSlotAssignments.maximumPhotoCount {
            pendingJamPhotos = nil
            isShowingJamPhotoChooser = true
        } else {
            jamPhotos = selectedPhotos
            isShowingJamPicker = true
        }
    }

    private func presentJamPickerAfterPhotoChoice() {
        guard let pendingJamPhotos else { return }
        self.pendingJamPhotos = nil
        jamPhotos = pendingJamPhotos
        isShowingJamPicker = true
    }

    private func deletionMessage(for result: PhotoLibraryViewModel.BatchDeletionResult) -> String {
        let deletedCount = result.deletedIDs.count
        let remainingCount = result.remainingIDs.count

        if deletedCount == 0 {
            return "No photos were deleted. The selected photos remain available."
        }

        return "Deleted \(deletedCount) of \(result.requestedIDs.count) photos. "
            + "\(remainingCount) photo\(remainingCount == 1 ? "" : "s") could not be deleted."
    }
}

private struct GalleryAddToJamButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary.opacity(isEnabled ? 1 : 0.36))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .opacity(isEnabled ? 1 : 0.62)
            .glassEffect(
                .regular
                    .tint(.primary.opacity(isEnabled ? (configuration.isPressed ? 0.10 : 0.06) : 0.03))
                    .interactive(isEnabled),
                in: Capsule()
            )
            .contentShape(.interaction, Capsule())
    }
}

private struct ChooseJamPhotosSheet: View {
    let library: PhotoLibraryViewModel
    let photos: [PhotoSound]
    let onContinue: ([PhotoSound]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedPhotoIDs = Set<UUID>()
    @State private var selectionLimitFeedbackToken = 0

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var maximumPhotoCount: Int {
        JamSlotAssignments.maximumPhotoCount
    }

    private var selectedPhotos: [PhotoSound] {
        photos.filter { selectedPhotoIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A Jam can use up to \(maximumPhotoCount) photos.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("\(selectedPhotoIDs.count) of \(maximumPhotoCount)")
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(photos) { photo in
                            Button {
                                toggle(photo.id)
                            } label: {
                                SoundCellView(
                                    sound: photo,
                                    coverData: library.coverDataByID[photo.id],
                                    isPlaying: library.playingID == photo.id,
                                    isRefining: library.refiningMetadataIDs.contains(photo.id),
                                    isSelecting: true,
                                    isSelected: selectedPhotoIDs.contains(photo.id),
                                    reduceMotion: reduceMotion
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(photo.displayTitle)
                            .accessibilityValue(
                                selectedPhotoIDs.contains(photo.id)
                                    ? "Selected"
                                    : "Not selected"
                            )
                            .accessibilityHint(selectionHint(for: photo.id))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 120)
                }
            }
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    onContinue(selectedPhotos)
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(DapPrimaryGlassButtonStyle(shape: .capsule))
                .disabled(selectedPhotoIDs.isEmpty)
                .accessibilityLabel("Continue with \(selectedPhotoIDs.count) photos")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .navigationTitle("Choose Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
                }
            }
        }
        .sensoryFeedback(.warning, trigger: selectionLimitFeedbackToken)
    }

    private func toggle(_ id: UUID) {
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.remove(id)
        } else if selectedPhotoIDs.count < maximumPhotoCount {
            selectedPhotoIDs.insert(id)
        } else {
            selectionLimitFeedbackToken += 1
        }
    }

    private func selectionHint(for id: UUID) -> String {
        if selectedPhotoIDs.contains(id) {
            return "Removes this photo from the Jam selection."
        }
        if selectedPhotoIDs.count >= maximumPhotoCount {
            return "Selection limit reached. Choose up to \(maximumPhotoCount) photos."
        }
        return "Adds this photo to the Jam selection."
    }
}

// MARK: - Sound Cell

private struct SoundCellView: View {
    let sound: PhotoSound
    let coverData: Data?
    let isPlaying: Bool
    let isRefining: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let reduceMotion: Bool

    var body: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                ZStack(alignment: .topLeading) {
                    coverImage

                    if isRefining {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.6)
                            .tint(.white)
                            .padding(4)
                    }

                    if isSelecting && isSelected {
                        Color.black.opacity(0.5)

                        Image(systemName: "checkmark")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.15),
                value: isSelected
            )
            .accessibilityLabel(sound.name ?? sound.sequence.displayLabel)
            .accessibilityHint(
                isSelecting
                    ? "Selects or deselects this photo."
                    : "Opens the Photo Inspector."
            )
            .accessibilityValue(
                isSelecting ? (isSelected ? "Selected" : "Not selected") : ""
            )
            .accessibilityAddTraits(isSelecting && isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var coverImage: some View {
        // Data is already in memory from library.coverDataByID — no disk I/O here.
        if let data = coverData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Rectangle()
                .fill(.secondary.opacity(0.18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct GallerySharePresentation: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct GalleryActivityViewController: UIViewControllerRepresentable {
    let activityItems: [URL]
    let onCompletion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems.map { $0 as Any },
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            onCompletion()
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private enum GalleryShareError: LocalizedError {
    case missingCover(String)
    case incompletePreparation

    var errorDescription: String? {
        switch self {
        case .missingCover(let title):
            "Could not prepare \"\(title)\" for sharing."
        case .incompletePreparation:
            "Could not prepare all selected photos for sharing."
        }
    }
}

private extension Color {
    static let galleryBackground = Color(uiColor: .systemBackground)
}
