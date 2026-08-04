import SwiftUI
import UIKit

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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingDeleteError = false
    @State private var isShowingJamPicker = false
    @State private var photoStoryExportSnapshot: PhotoStoryExportSnapshot?
    @State private var isDeleting = false
    @State private var didAddToJam = false

    private var metadataState: PhotoLibraryViewModel.PhotoMetadataState {
        library.metadataState(for: sound)
    }

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

    private var titleText: String {
        switch metadataState {
        case .generating where sound.trimmedName == nil:
            "Naming photo…"
        default:
            sound.displayTitle
        }
    }

    private var showsNamingProgress: Bool {
        metadataState == .generating && sound.trimmedName == nil
    }

    private var primaryDescription: String? {
        guard let description = sound.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else { return nil }
        return description
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                cover
                details
            }
            .padding(.top, 34)
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
        .navigationTransition(.automatic)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        photoStoryExportSnapshot = makePhotoStoryExportSnapshot()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(coverData == nil)

                    Button(role: .destructive) {
                        DispatchQueue.main.async {
                            isShowingDeleteConfirmation = true
                        }
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
        .alert("Delete Photo?", isPresented: $isShowingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}

            Button("Delete", role: .destructive, action: deletePhoto)
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Couldn't Delete Photo", isPresented: $isShowingDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again.")
        }
        .sheet(isPresented: $isShowingJamPicker) {
            AddToJamSheet(
                library: library,
                sound: sound,
                isPresented: $isShowingJamPicker
            ) {
                handleJamAdded()
            }
        }
        .fullScreenCover(item: $photoStoryExportSnapshot) { snapshot in
            PhotoStoryExportSheet(snapshot: snapshot)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 10) {
            if showsNamingProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(titleText)
                        .font(.headline.weight(.semibold))
                }
                .foregroundStyle(foreground)
                .accessibilityLabel("Naming photo")
            } else {
                Text(titleText)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(foreground)
            }
        }
        .padding(.horizontal, 24)
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

    private var details: some View {
        VStack(spacing: 12) {
            titleBlock

            if let primaryDescription {
                Text(primaryDescription)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(secondaryForeground)
                    .padding(.horizontal, 22)
            }

            musicInfo
        }
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
                    Label(
                        isPlaying ? "Stop" : "Play",
                        systemImage: isPlaying ? "stop.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    InspectorButtonStyle(
                        background: .white.opacity(0.9),
                        foreground: .black
                    )
                )
                .accessibilityLabel(isPlaying ? "Stop" : "Play")

                Button {
                    isShowingJamPicker = true
                } label: {
                    Label(
                        didAddToJam ? "Added to Jam" : "Add to Jam",
                        systemImage: didAddToJam ? "checkmark" : "dot.radiowaves.left.and.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    InspectorButtonStyle(
                        background: .white.opacity(0.9),
                        foreground: .black
                    )
                )
                .accessibilityLabel(didAddToJam ? "Added to Jam" : "Add to Jam")
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

    private func makePhotoStoryExportSnapshot() -> PhotoStoryExportSnapshot? {
        PhotoStoryExportSnapshot(sound: sound, coverData: coverData)
    }

    private func handleJamAdded() {
        didAddToJam = true
        UIAccessibility.post(notification: .announcement, argument: "Added to Jam")

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard didAddToJam else { return }
            if reduceMotion {
                didAddToJam = false
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    didAddToJam = false
                }
            }
        }
    }
}

struct AddToJamSheet: View {
    let library: PhotoLibraryViewModel
    let photos: [PhotoSound]
    @Binding var isPresented: Bool
    let onAdded: () -> Void

    @State private var state = JamLibraryState()

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    init(
        library: PhotoLibraryViewModel,
        photos: [PhotoSound],
        isPresented: Binding<Bool>,
        onAdded: @escaping () -> Void
    ) {
        self.library = library
        self.photos = photos
        self._isPresented = isPresented
        self.onAdded = onAdded
    }

    init(
        library: PhotoLibraryViewModel,
        sound: PhotoSound,
        isPresented: Binding<Bool>,
        onAdded: @escaping () -> Void
    ) {
        self.init(
            library: library,
            photos: [sound],
            isPresented: isPresented,
            onAdded: onAdded
        )
    }

    private var photoIDs: [UUID] {
        photos.map(\.id)
    }

    private var playablePhotoIDs: Set<UUID> {
        Set(photos.filter { !$0.sequence.notes.isEmpty }.map(\.id))
    }

    private var selectionIssueMessage: String? {
        switch JamSlotAssignments().addingPhotoIDs(
            photoIDs,
            playableIDs: playablePhotoIDs
        ) {
        case .added:
            return nil
        case .alreadyIncluded:
            return "The selected photos cannot be added to a new Jam."
        case .full(let availableSlots):
            return "Only \(availableSlots) of \(photos.count) selected photos can fit in a Jam. Select up to \(availableSlots)."
        case .unplayable(let count):
            return "\(count) selected photo\(count == 1 ? "" : "s") cannot be added because it has no musical notes."
        }
    }

    private var nonPlayableMessage: String? { selectionIssueMessage }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                content

                if shouldShowCreateButton {
                    createButton
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
            }
            .navigationTitle("Add to Jam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented = false
                    }
                    label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }
        .task {
            await state.loadIfNeeded()
        }
        .alert("Jam Error", isPresented: errorPresented) {
            Button("OK") {
                state.errorMessage = nil
            }
        } message: {
            Text(state.errorMessage ?? "Something went wrong.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.loadState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView("Could not load Jams", systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let nonPlayableMessage {
                        ContentUnavailableView(
                            nonPlayableMessage,
                            systemImage: "waveform.slash"
                        )
                        .frame(maxWidth: .infinity)
                    }

                    if state.jams.isEmpty && state.draftJam == nil && selectionIssueMessage == nil {
                        ContentUnavailableView(
                            "No Jams Yet",
                            systemImage: "waveform.path.ecg",
                            description: Text("Create a Jam to save this photo for later.")
                        )
                        .frame(maxWidth: .infinity)
                    }

                    LazyVGrid(columns: columns, spacing: 18) {
                        if let draft = state.draftJam {
                            JamCard(
                                id: draft.id,
                                name: draft.name,
                                coverDescriptor: .empty(jamID: draft.id),
                                detailText: "New Jam",
                                status: nil,
                                isEditing: state.editingJamID == draft.id,
                                editingPlaceholder: PersistedJam.defaultName,
                                editingName: $state.editingName,
                                showsActions: false,
                                showsConfirmAction: false,
                                isOpenDisabled: true,
                                onOpen: {},
                                onRename: {},
                                onDelete: {
                                    state.cancelDraftCreation()
                                },
                                onConfirmEdit: {
                                    Task { await createJamAndAddPhotos() }
                                },
                                onCancelEdit: {
                                    state.cancelDraftCreation()
                                }
                            )
                        }

                        ForEach(state.jams) { jam in
                            let availability = availability(for: jam)

                            JamCard(
                                id: jam.id,
                                name: jam.name,
                                coverDescriptor: JamCoverDescriptor(jam: jam, sounds: library.items),
                                detailText: "\(jam.slotAssignments.allPhotoIDs.count) of \(JamSlotAssignments.maximumPhotoCount) photos",
                                status: availability.status,
                                isEditing: false,
                                editingPlaceholder: "Jam name",
                                editingName: .constant(""),
                                showsActions: false,
                                showsConfirmAction: true,
                                isOpenDisabled: !availability.isSelectable,
                                onOpen: {
                                    Task { await addPhotos(to: jam) }
                                },
                                onRename: {},
                                onDelete: {},
                                onConfirmEdit: {},
                                onCancelEdit: {}
                            )
                            .accessibilityHint(availability.accessibilityHint)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, shouldShowCreateButton ? 120 : 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var shouldShowCreateButton: Bool {
        selectionIssueMessage == nil && state.editingJamID == nil
    }

    private var createButton: some View {
        Button {
            state.beginDraftCreation()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("Create Jam")
                    .font(.headline)
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
        .buttonStyle(.plain)
        .accessibilityLabel("Create Jam")
    }

    private func availability(for jam: PersistedJam) -> JamAvailability {
        let assignments = jam.slotAssignments.jamSlotAssignments
        let capacityStatus = capacityStatus(for: assignments)

        switch assignments.addingPhotoIDs(
            photoIDs,
            playableIDs: playablePhotoIDs
        ) {
        case .added:
            return JamAvailability(
                isSelectable: true,
                status: capacityStatus,
                accessibilityHint: "Adds all selected photos to the Jam."
            )
        case .alreadyIncluded(let count):
            let noun = count == 1 ? "photo is" : "photos are"
            return JamAvailability(
                isSelectable: false,
                status: capacityStatus,
                accessibilityHint: "\(count) selected \(noun) already in this Jam. No photos will be added."
            )
        case .full:
            return JamAvailability(
                isSelectable: false,
                status: capacityStatus,
                accessibilityHint: "This Jam does not have enough capacity for all selected photos. No photos will be added."
            )
        case .unplayable(let count):
            return JamAvailability(
                isSelectable: false,
                status: capacityStatus,
                accessibilityHint: "\(count) selected photo\(count == 1 ? "" : "s") have no musical notes. No photos will be added."
            )
        }
    }

    private func capacityStatus(for assignments: JamSlotAssignments) -> JamCard.Status {
        let availablePhotoCount = assignments.availablePhotoCount
        let text: String
        let style: JamCard.Status.Style

        switch availablePhotoCount {
        case 0:
            text = "Full"
            style = .warning
        case 1:
            text = "1 spot available"
            style = .neutral
        default:
            text = "\(availablePhotoCount) spots available"
            style = .neutral
        }

        return JamCard.Status(text: text, style: style)
    }

    private func addPhotos(to jam: PersistedJam) async {
        let result = jam.slotAssignments.jamSlotAssignments.addingPhotoIDs(
            photoIDs,
            playableIDs: playablePhotoIDs
        )

        guard case .added(let updatedAssignments) = result else {
            state.errorMessage = message(for: result)
            return
        }

        var updatedJam = jam
        updatedJam.slotAssignments = PersistedJamSlotAssignments(updatedAssignments)

        guard await state.saveJam(updatedJam) != nil else { return }
        onAdded()
        isPresented = false
    }

    private func createJamAndAddPhotos() async {
        guard let jam = await state.confirmDraftCreation() else { return }
        await addPhotos(to: jam)
    }

    private func message(for result: JamSlotAssignments.AddPhotosResult) -> String {
        switch result {
        case .added:
            return ""
        case .alreadyIncluded(let count):
            return "\(count) selected photo\(count == 1 ? "" : "s") already belong to this Jam. No photos were added."
        case .full(let availableSlots):
            if availableSlots == 0 {
                return "This Jam is full. No photos were added."
            }
            let noun = availableSlots == 1 ? "spot is" : "spots are"
            return "This Jam has \(availableSlots) available \(noun), but all selected photos must be added together. No photos were added."
        case .unplayable(let count):
            return "\(count) selected photo\(count == 1 ? "" : "s") have no musical notes. No photos were added."
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )
    }
}

private struct JamAvailability {
    let isSelectable: Bool
    let status: JamCard.Status?
    let accessibilityHint: String
}

private struct InspectorButtonStyle: ButtonStyle {
    let background: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .foregroundStyle(foreground)
            .background(
                background.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
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
