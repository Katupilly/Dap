import SwiftUI
import UIKit
import OSLog

private let jamStepsPerBar = MusicSequence.steps
private let jamBPM = 96.0

struct JamView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    let library: PhotoLibraryViewModel
    let isActive: Bool
    let initialJam: PersistedJam?
    let initialCoverDescriptor: JamCoverDescriptor?
    let onClose: (() async -> Void)?

    private let arrangementBuilder = JamArrangementBuilder(bpm: Int(jamBPM))

    @State private var session = JamSessionState()
    @State private var visualTransport = JamVisualTransportState()
    @State private var selectedPanel: JamControlPanel = .none
    @State private var isPanelPresented = false
    @State private var selectedJamRole: JamRole?
    @State private var selectedBassIntent: BassPatternIntent = .steady
    @State private var selectedHarmonyIntent: HarmonyPatternIntent = .sustained
    @State private var selectedMelodyIntent: MelodyPhraseIntent = .subtle
    @State private var playbackController = JamPlaybackController()
    @State private var isPhotoSelectorPresented = false
    @State private var swapArrangementVersion = 0
    @State private var transportTask: Task<Void, Never>?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var persistenceError: JamPersistenceError?
    @State private var hasAppliedInitialJam = false
    @State private var panelBackdropImage: UIImage?
    @State private var jamViewportSize: CGSize = .zero
    @State private var jamSequencerFrame: CGRect = .zero
    @State private var resolvedJamCoverDescriptor: JamCoverDescriptor?
    @State private var resolvedJamCoverImage: UIImage?
    @State private var panelBackdropTask: Task<Void, Never>?
    @State private var selectedPhotoImagesByID: [UUID: UIImage] = [:]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dap", category: "JamView")
    private let transportPollInterval: Duration = .milliseconds(33)
    private let autosaveDebounce: Duration = .milliseconds(500)

    private let panelDockGap: CGFloat = 14
    private let bottomReserve: CGFloat = 168
    private let dockHeight: CGFloat = 68
    private let dockBottomInset: CGFloat = 82
    private let playbackBottomInset: CGFloat = 16
    private let topHeaderInset: CGFloat = 18
    private let headerThumbnailSize: CGFloat = 24
    private let headerThumbnailCornerRadius: CGFloat = 5
    private let effectsPanelWidth: CGFloat = 352
    private let effectsPanelHeight: CGFloat = 392
    private let effectsPanelCornerRadius: CGFloat = 22

    private var photoSwapAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.16)
            : .spring(response: 0.22, dampingFraction: 1.0)
    }

    init(
        library: PhotoLibraryViewModel,
        isActive: Bool,
        initialJam: PersistedJam? = nil,
        initialCoverDescriptor: JamCoverDescriptor? = nil,
        onClose: (() async -> Void)? = nil
    ) {
        self.library = library
        self.isActive = isActive
        self.initialJam = initialJam
        self.initialCoverDescriptor = initialCoverDescriptor
        self.onClose = onClose
    }

    private var selectedSounds: [PhotoSound] {
        session.slotAssignments.allPhotoIDs.compactMap { id in
            library.items.first(where: { $0.id == id })
        }
    }

    private var playableSelectedSounds: [PhotoSound] {
        selectedSounds.filter { !$0.sequence.notes.isEmpty }
    }

    private var assignedSounds: [AssignedSound] {
        let roleByID = session.slotAssignments.assignedRolesByID
        let orderedRoles: [JamRole] = [.bass, .harmony, .melody]
        var seen: Set<UUID> = []
        var result: [AssignedSound] = []

        for sound in playableSelectedSounds where !seen.contains(sound.id) {
            guard let role = roleByID[sound.id] else { continue }
            seen.insert(sound.id)
            result.append(AssignedSound(sound: sound, role: role))
        }

        return orderedRoles.compactMap { role in
            result.first(where: { $0.role == role })
        }
    }

    private var canPlay: Bool {
        !playableSelectedSounds.isEmpty
    }

    private var playbackAction: PlaybackAction {
        session.isPlaying ? .stop : .play
    }

    private var currentDrumKitSubtitle: String {
        return session.drumKitSelection.displayName
    }

    private var hasAnySelection: Bool {
        !selectedSounds.isEmpty
    }

    private func photoColor(for role: JamRole) -> Color? {
        let roleID: UUID?
        switch role {
        case .bass: roleID = session.slotAssignments.bass
        case .harmony: roleID = session.slotAssignments.harmony
        case .melody: roleID = session.slotAssignments.melody
        }
        guard let roleID,
              let sound = library.items.first(where: { $0.id == roleID })
        else { return nil }
        let pitch = PitchClass(rawValue: sound.sequence.harmony.rootPitchClass) ?? .c
        return Color(jamRGB: RetroCoverRenderer.tonalPalette(for: pitch).base)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemBackground)

            GeometryReader { _ in
                ViewThatFits(in: .vertical) {
                    fixedSessionLayout
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    ScrollView {
                        sessionContentStack
                    }
                    .scrollIndicators(.hidden)
                }
            }

            if isPanelPresented || selectedPanel != .none {
                panelBackdropLayer
                    .zIndex(6)

                liveSequencerOverlay
                    .zIndex(6.5)
            }

            if isPanelPresented {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closePanel()
                    }
                    .zIndex(7)
            }

            if hasAnySelection {
                panelLayer
                    .zIndex(8)

                JamDockBar(
                    selectedPanel: selectedPanel,
                    isPanelPresented: isPanelPresented,
                    vibePosition: session.vibePosition,
                    canOpenArrangePanel: canOpenArrangePanel,
                    arrangeAvailability: arrangeAvailability,
                    onPanelToggle: { target in
                        handlePanelToggle(target)
                    }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 82)
                .zIndex(9)

                playbackButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .zIndex(5)
            }
        }
        .coordinateSpace(.named("jamViewport"))
        .onGeometryChange(for: CGSize.self) { geometry in
            geometry.size
        } action: { size in
            jamViewportSize = size
        }
        .sensoryFeedback(.selection, trigger: playbackController.appliedArrangementVersion)
        .sensoryFeedback(.success, trigger: swapArrangementVersion)
        .onChange(of: session.effectSettings) { _, newSettings in
            let bpm = session.activeArrangement.map { Double($0.sequence.harmony.bpm) } ?? 96.0
            library.setJamEffects(newSettings, bpm: bpm)
            scheduleAutosave()
        }
        .onChange(of: session.slotAssignments) { oldAssignments, assignments in
            if !session.isPlaying {
                session.activeArrangement = buildArrangement(
                    for: assignments,
                    bassVariation: session.bassVariation,
                    harmonyVariation: session.harmonyVariation,
                    melodyVariation: session.melodyVariation,
                    buildMode: .standard
                )
            }
            synchronizeSelectionState(previousAssignments: oldAssignments, newAssignments: assignments)
            refreshSelectedPhotoImages()
            scheduleAutosave()
        }
        .onChange(of: session.drumKitSelection) { _, _ in
            if !session.isPlaying {
                session.activeArrangement = buildArrangement()
            }
            scheduleAutosave()
        }
        .onChange(of: session.vibePosition) { _, _ in
            if !session.isPlaying {
                session.activeArrangement = buildArrangement()
            }
            scheduleAutosave()
        }
        .onChange(of: session.jamName) { _, _ in
            scheduleAutosave()
        }
        .sheet(isPresented: $isPhotoSelectorPresented) {
            JamPhotoSelectorSheet(
                sounds: library.items,
                coverDataByID: library.coverDataByID,
                selectedPhotoIDs: session.slotAssignments.allPhotoIDs,
                isPresented: $isPhotoSelectorPresented,
                onConfirmSelection: confirmPhotoSelection
            )
        }
        .onAppear {
            library.setTransientLoopUpdatePreparedHandler {
                playbackController.markLoopUpdatePrepared()
            }
            if !hasAppliedInitialJam, let initialJam {
                hasAppliedInitialJam = true
                applyPersistedJam(initialJam)
            }
            syncAllArrangeDrafts()
            synchronizeSelectionState(previousAssignments: session.slotAssignments, newAssignments: session.slotAssignments)
            refreshSelectedPhotoImages()
        }
        .onDisappear {
            library.clearTransientLoopUpdatePreparedHandler()
            Task { await flushAutosave() }
            clearTransportAndPlayback()
            selectedJamRole = nil
            selectedPanel = .none
            isPanelPresented = false
            cancelPanelBackdropTask()
            panelBackdropImage = nil
            resolvedJamCoverDescriptor = nil
            resolvedJamCoverImage = nil
            selectedPhotoImagesByID = [:]
        }
        .onChange(of: isActive) { _, isActive in
            if isActive {
                refreshSelectedPhotoImages()
                return
            }
            Task { await flushAutosave() }
            clearTransportAndPlayback()
            selectedJamRole = nil
            selectedPanel = .none
            isPanelPresented = false
            cancelPanelBackdropTask()
            panelBackdropImage = nil
            resolvedJamCoverDescriptor = nil
            resolvedJamCoverImage = nil
            selectedPhotoImagesByID = [:]
        }
        .onChange(of: library.items.map(\.id)) { _, itemIDs in
            let validIDs = Set(itemIDs)
            let playableIDs = Set(
                library.items.compactMap { sound in
                    sound.sequence.notes.isEmpty ? nil : sound.id
                }
            )
            let previousAssignments = session.slotAssignments
            let cleanedAssignments = session.slotAssignments.pruningInvalidIDs(
                validIDs: validIDs,
                playableIDs: playableIDs
            )

            guard cleanedAssignments != previousAssignments else { return }

            if session.isPlaying && cleanedAssignments.hasDifferentActiveSlots(from: previousAssignments) {
                sendPendingArrangementToPlayer()
            } else if !session.isPlaying {
                session.activeArrangement = buildArrangement(
                    for: cleanedAssignments,
                    bassVariation: session.bassVariation,
                    harmonyVariation: session.harmonyVariation,
                    melodyVariation: session.melodyVariation,
                    buildMode: .standard
                )
            }

            session.slotAssignments = cleanedAssignments
            synchronizeSelectionState(previousAssignments: previousAssignments, newAssignments: cleanedAssignments)
            refreshSelectedPhotoImages()
            scheduleAutosave()
        }
        .onChange(of: library.isTransientPlaybackActive) { _, isActive in
            guard !isActive, session.isPlaying else { return }
            clearTransportState()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            Task { await flushAutosave() }
        }
    }

    // MARK: - Jam persistence

    private var fixedSessionLayout: some View {
        VStack(spacing: 18) {
            sessionHeader

            sessionBody

            Spacer(minLength: bottomReserve)
        }
        .padding(.top, topHeaderInset)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sessionContentStack: some View {
        VStack(spacing: 18) {
            sessionHeader

            sessionBody
        }
        .padding(.top, topHeaderInset)
        .padding(.horizontal, 20)
        .padding(.bottom, bottomReserve)
        .frame(maxWidth: .infinity)
    }

    private var sessionHeader: some View {
        HStack(spacing: 10) {
            Button {
                closeSessionAndReturnToLibrary()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.secondary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Jam Library")

            sessionHeaderCover

            Text(sessionDisplayName)
                .font(.custom("ZTTalk-Bold", size: 22, relativeTo: .title2))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var sessionHeaderCover: some View {
        if let sessionHeaderCoverDescriptor {
            JamCoverArtwork(
                descriptor: sessionHeaderCoverDescriptor,
                targetSize: CGSize(width: 320, height: 320),
                cornerRadius: headerThumbnailCornerRadius
            )
            .frame(width: headerThumbnailSize, height: headerThumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: headerThumbnailCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: headerThumbnailCornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
        } else {
            Color.clear
                .frame(width: headerThumbnailSize, height: headerThumbnailSize)
                .overlay {
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: headerThumbnailCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: headerThumbnailCornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private var sessionBody: some View {
        Group {
            if hasAnySelection {
                sequencerAndStatus
            }

            if selectedSounds.isEmpty {
                emptyState
            } else {
                selectedPhotoArea
            }
        }
    }

    private func loadPersistedJam(id: UUID) {
        Task {
            do {
                let jam = try await JamStore.shared.load(id: id)
                await MainActor.run {
                    applyPersistedJam(jam)
                }
            } catch {
                await MainActor.run {
                    handlePersistenceError(error, context: "load")
                }
            }
        }
    }

    @MainActor
    private func applyPersistedJam(_ jam: PersistedJam) {
        cancelAutosaveTask()
        clearTransportAndPlayback()

        session.activeJamID = jam.id
        session.jamName = PersistedJam.normalizedName(jam.name)
        session.jamCreatedAt = jam.createdAt
        session.vibePosition = jam.vibePosition.cgPoint
        session.drumKitSelection = MusicDrumKitSelection(persistedValue: jam.drumKitSelection)
        session.effectSettings = jam.effectSettings.jamEffectSettings
        session.bassVariation = jam.bassVariation
        session.harmonyVariation = jam.harmonyVariation
        session.melodyVariation = jam.melodyVariation
        session.isPlaying = false
        visualTransport.reset()
        playbackController.clearPendingState()
        playbackController.clearDrumKitPendingFeedback()
        selectedPanel = .none
        isPanelPresented = false
        cancelPanelBackdropTask()
        panelBackdropImage = nil
        resolvedJamCoverDescriptor = nil
        resolvedJamCoverImage = nil
        selectedJamRole = nil
        syncAllArrangeDrafts()

        let validIDs = Set(library.items.map(\.id))
        let playableIDs = Set(
            library.items.compactMap { sound in
                sound.sequence.notes.isEmpty ? nil : sound.id
            }
        )
        let persistedAssignments = jam.slotAssignments.jamSlotAssignments
        let reconciledAssignments = persistedAssignments.pruningInvalidIDs(
            validIDs: validIDs,
            playableIDs: playableIDs
        )

        session.slotAssignments = reconciledAssignments
        refreshSelectedPhotoImages()
        session.activeArrangement = buildArrangement(
            for: reconciledAssignments,
            bassVariation: session.bassVariation,
            harmonyVariation: session.harmonyVariation,
            melodyVariation: session.melodyVariation,
            buildMode: .standard
        )

        if snapshotDiffersFromPersistedJam(jam) {
            scheduleAutosave(debounce: .zero)
        }
    }

    private func closeSessionAndReturnToLibrary() {
        Task {
            await flushAutosave()
            clearTransportAndPlayback()
            selectedJamRole = nil
            selectedPanel = .none
            isPanelPresented = false
            cancelPanelBackdropTask()
            panelBackdropImage = nil
            resolvedJamCoverDescriptor = nil
            resolvedJamCoverImage = nil
            selectedPhotoImagesByID = [:]
            visualTransport.reset()
            await onClose?()
        }
    }

    @MainActor
    private func currentPersistedJamSnapshot() -> PersistedJam? {
        guard let id = session.activeJamID,
              let createdAt = session.jamCreatedAt else {
            return nil
        }

        return PersistedJam(
            schemaVersion: PersistedJam.currentSchemaVersion,
            id: id,
            name: PersistedJam.normalizedName(session.jamName),
            createdAt: createdAt,
            updatedAt: Date(),
            slotAssignments: PersistedJamSlotAssignments(session.slotAssignments),
            vibePosition: PersistedPoint(session.vibePosition),
            drumKitSelection: session.drumKitSelection.persistedValue,
            effectSettings: PersistedJamEffectSettings(session.effectSettings),
            melodyVariation: session.melodyVariation,
            bassVariation: session.bassVariation,
            harmonyVariation: session.harmonyVariation
        )
    }

    @MainActor
    private func scheduleAutosave(debounce: Duration? = nil) {
        guard session.activeJamID != nil else { return }
        let delay = debounce ?? autosaveDebounce
        cancelAutosaveTask()

        autosaveTask = Task { @MainActor in
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await saveCurrentJamSnapshot()
        }
    }

    @MainActor
    private func flushAutosave() async {
        guard session.activeJamID != nil else { return }
        cancelAutosaveTask()
        await saveCurrentJamSnapshot()
    }

    @MainActor
    private func saveCurrentJamSnapshot() async {
        guard let snapshot = currentPersistedJamSnapshot() else { return }

        do {
            _ = try await JamStore.shared.save(snapshot)
            persistenceError = nil
        } catch {
            handlePersistenceError(error, context: "save")
        }
    }

    @MainActor
    private func cancelAutosaveTask() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    @MainActor
    private func snapshotDiffersFromPersistedJam(_ jam: PersistedJam) -> Bool {
        guard let snapshot = currentPersistedJamSnapshot() else { return false }
        return snapshot.name != jam.name
            || snapshot.slotAssignments != jam.slotAssignments
            || snapshot.vibePosition != jam.vibePosition
            || snapshot.drumKitSelection != jam.drumKitSelection
            || snapshot.effectSettings != jam.effectSettings
            || snapshot.melodyVariation != jam.melodyVariation
            || snapshot.bassVariation != jam.bassVariation
            || snapshot.harmonyVariation != jam.harmonyVariation
    }

    @MainActor
    private func handlePersistenceError(_ error: Error, context: String) {
        if let storeError = error as? JamStore.StoreError {
            switch storeError {
            case .notFound:
                persistenceError = .notFound
                logger.error("Jam persistence \(context, privacy: .public) failed: not found")
            case .corruptedFile(let id):
                persistenceError = .corruptedFile(id)
                logger.error("Jam persistence \(context, privacy: .public) failed: corrupted file \(id.uuidString, privacy: .public)")
            case .unsupportedSchemaVersion(let version):
                persistenceError = .unsupportedSchemaVersion(version)
                logger.error("Jam persistence \(context, privacy: .public) failed: unsupported schema \(version, privacy: .public)")
            }
        } else {
            persistenceError = .writeFailed
            logger.error("Jam persistence \(context, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Panel presentation

    @MainActor
    private func renderPanelBackdrop(jamCoverImage: UIImage?) -> UIImage? {
        guard jamViewportSize.width > 0,
              jamViewportSize.height > 0,
              jamViewportSize.width.isFinite,
              jamViewportSize.height.isFinite,
              displayScale > 0 else {
            return nil
        }

        let content = JamPanelBackdropContent(
            displayName: sessionDisplayName,
            jamCoverImage: jamCoverImage,
            photos: panelBackdropPhotos(),
            hasAnySelection: hasAnySelection,
            hasSelectedSounds: !selectedSounds.isEmpty,
            playbackAction: playbackAction,
            canPlay: canPlay,
            colorScheme: colorScheme,
            reduceMotion: reduceMotion
        )
        .frame(
            width: jamViewportSize.width,
            height: jamViewportSize.height,
            alignment: .topLeading
        )
        .blur(radius: 2.5)
        .clipped()
        .environment(\.colorScheme, colorScheme)
        .environment(\.displayScale, displayScale)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(jamViewportSize)
        renderer.scale = displayScale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    @MainActor
    private func resolvedJamCoverImageForBackdrop() async -> UIImage? {
        guard let descriptor = sessionHeaderCoverDescriptor else { return nil }

        if resolvedJamCoverDescriptor == descriptor, let resolvedJamCoverImage {
            return resolvedJamCoverImage
        }

        let data = await JamCoverRenderer.shared.data(
            for: descriptor,
            size: CGSize(width: 320, height: 320),
            scale: displayScale
        )
        guard !Task.isCancelled,
              let image = UIImage(data: data, scale: displayScale) else {
            return nil
        }

        resolvedJamCoverDescriptor = descriptor
        resolvedJamCoverImage = image
        return image
    }

    private func panelBackdropPhotos() -> [JamPanelBackdropPhoto] {
        JamRole.allCases.map { role in
            let photoID = session.slotAssignments.photoID(for: role)
            let sound = photoID.flatMap { id in
                library.items.first(where: { $0.id == id })
            }
            let pitch = sound.flatMap { PitchClass(rawValue: $0.sequence.harmony.rootPitchClass) } ?? .c

            return JamPanelBackdropPhoto(
                role: role,
                hasPhoto: photoID != nil,
                image: photoID.flatMap { selectedPhotoImagesByID[$0] },
                noteLabel: sound?.sequence.harmony.rootName ?? "",
                accentColor: sound == nil ? nil : Color(jamRGB: RetroCoverRenderer.tonalPalette(for: pitch).base),
                isActive: photoID.map { visualTransport.activeSoundIDs.contains($0) } ?? false,
                isSelected: selectedJamRole == role
            )
        }
    }

    private func refreshSelectedPhotoImages() {
        let selectedIDs = Set(session.slotAssignments.allPhotoIDs)
        var nextImages = selectedPhotoImagesByID.filter { selectedIDs.contains($0.key) }
        var didChange = nextImages.count != selectedPhotoImagesByID.count

        for id in selectedIDs where nextImages[id] == nil {
            guard let data = library.coverDataByID[id], let image = UIImage(data: data) else { continue }
            nextImages[id] = image
            didChange = true
        }

        if didChange {
            selectedPhotoImagesByID = nextImages
        }
    }

    private var panelBackdropLayer: some View {
        ZStack(alignment: .topLeading) {
            if let panelBackdropImage {
                Image(uiImage: panelBackdropImage)
                    .resizable()
                    .frame(
                        width: jamViewportSize.width,
                        height: jamViewportSize.height,
                        alignment: .topLeading
                    )
                    .clipped()
            }

            Color(uiColor: .systemBackground)
                .opacity(0.12)
        }
        .frame(
            width: jamViewportSize.width,
            height: jamViewportSize.height,
            alignment: .topLeading
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .opacity(isPanelPresented ? 1 : 0)
        .animation(backdropFadeAnimation, value: isPanelPresented)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var liveSequencerOverlay: some View {
        if hasAnySelection,
           jamSequencerFrame.width > 0,
           jamSequencerFrame.height > 0 {
            sequencerAndStatusContent
                .frame(width: jamSequencerFrame.width, height: jamSequencerFrame.height)
                .position(x: jamSequencerFrame.midX, y: jamSequencerFrame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var backdropFadeAnimation: Animation {
        .easeOut(duration: reduceMotion ? 0.12 : 0.16)
    }

    @ViewBuilder
    private var panelLayer: some View {
        JamControlPanelHost(
            selectedPanel: selectedPanel,
            isPanelPresented: isPanelPresented,
            size: panelSize(for: selectedPanel),
            bottomPadding: dockBottomInset + dockHeight + panelDockGap,
            sizeAnimation: panelSizeAnimation,
            content: panelContent
        )
    }

    private func panelSize(for panel: JamControlPanel) -> CGSize {
        switch panel {
        case .kits:
            return CGSize(width: effectsPanelWidth, height: effectsPanelHeight)
        case .arrange:
            return arrangePanelSize
        case .vibe:
            return CGSize(width: 254, height: 254)
        case .effects, .none:
            return CGSize(width: effectsPanelWidth, height: effectsPanelHeight)
        }
    }

    private var panelSizeAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.28, dampingFraction: 0.96)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedPanel {
        case .kits:
            kitsPanelContent
        case .arrange:
            arrangePanelContent
        case .vibe:
            vibePanelContent
        case .effects:
            effectsPanelContent
        case .none:
            Color.clear
        }
    }

    private var expandedPanelFill: Color {
        switch colorScheme {
        case .dark:
            Color(red: 26 / 255, green: 26 / 255, blue: 30 / 255)
        default:
            Color(red: 243 / 255, green: 243 / 255, blue: 246 / 255)
        }
    }

    private var expandedPanelStroke: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.09)
        default:
            Color.black.opacity(0.09)
        }
    }

    private var vibePanelContent: some View {
        JamVibePanel(
            vibePosition: Binding(
                get: { session.vibePosition },
                set: { session.vibePosition = $0 }
            ),
            expandedPanelFill: expandedPanelFill,
            expandedPanelStroke: expandedPanelStroke,
            onPositionChanged: {
                if session.isPlaying {
                    sendPendingArrangementToPlayer()
                }
            }
        )
    }

    private var arrangePanelContent: some View {
        let context = arrangePanelContext
        return JamArrangePanel(
            title: context.title,
            subtitle: context.subtitle,
            options: context.options,
            selectedOption: context.selectedOption,
            buttonTitle: context.buttonTitle,
            isActionEnabled: context.isActionEnabled,
            fill: expandedPanelFill,
            stroke: expandedPanelStroke,
            onSelectOption: updateArrangeDraft,
            onApply: applySelectedArrangeVariation
        )
    }

    private var arrangePanelSize: CGSize {
        switch arrangePanelContext.role {
        case .bass, .harmony, .melody:
            return CGSize(width: 320, height: 316)
        case .none:
            return CGSize(width: 320, height: 188)
        }
    }

    private var kitsPanelContent: some View {
        let size = panelSize(for: .kits)
        return JamKitsPanel(
            selectedDrumKit: session.drumKitSelection,
            drumKitOptions: MusicDrumKitSelection.allCases,
            isDrumKitChangePending: playbackController.isDrumKitChangePending,
            isPreparedDrumKitChangePending: playbackController.isPreparedDrumKitChangePending,
            colorScheme: colorScheme,
            currentDrumKitSubtitle: currentDrumKitSubtitle,
            width: size.width,
            height: size.height,
            cornerRadius: effectsPanelCornerRadius,
            fill: expandedPanelFill,
            stroke: expandedPanelStroke,
            onSelect: selectDrumKit
        )
    }

    private var effectsPanelContent: some View {
        let size = panelSize(for: .effects)
        return JamEffectsPanel(
            effectSettings: Binding(
                get: { session.effectSettings },
                set: { session.effectSettings = $0 }
            ),
            colorScheme: colorScheme,
            width: size.width,
            height: size.height,
            cornerRadius: effectsPanelCornerRadius,
            fill: expandedPanelFill,
            stroke: expandedPanelStroke
        )
    }

    private func handlePanelToggle(_ target: JamControlPanel) {
        if target == .arrange, let selectedJamRole {
            syncArrangeDraft(for: selectedJamRole)
        }
        if selectedPanel == target && isPanelPresented {
            closePanel()
        } else if selectedPanel != .none && isPanelPresented {
            withAnimation(.easeOut(duration: 0.12)) {
                selectedPanel = target
            }
        } else {
            cancelPanelBackdropTask()
            panelBackdropTask = Task { @MainActor in
                let jamCoverImage = await resolvedJamCoverImageForBackdrop()
                guard !Task.isCancelled else { return }

                selectedPanel = target
                panelBackdropImage = renderPanelBackdrop(jamCoverImage: jamCoverImage)
                withAnimation(panelRevealAnimation) {
                    isPanelPresented = true
                }
            }
        }
    }

    private func closePanel() {
        cancelPanelBackdropTask()
        withAnimation(panelRevealAnimation) {
            isPanelPresented = false
        } completion: {
            if !isPanelPresented {
                selectedPanel = .none
                panelBackdropImage = nil
            }
        }
    }

    private var panelRevealAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.26, dampingFraction: 0.96)
    }

    @MainActor
    private func cancelPanelBackdropTask() {
        panelBackdropTask?.cancel()
        panelBackdropTask = nil
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Choose one to three photos to shape the jam vibe.",
                systemImage: "waveform.path.ecg"
            )
            .frame(maxWidth: .infinity)

            addPhotosButton(isLarge: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionDisplayName: String {
        session.activeJamID == nil
            ? PersistedJam.normalizedName(initialJam?.name ?? PersistedJam.defaultName)
            : session.jamName
    }

    private var sessionHeaderCoverDescriptor: JamCoverDescriptor? {
        if let activeJamID = session.activeJamID {
            return JamCoverDescriptor(
                jamID: activeJamID,
                slotAssignments: session.slotAssignments,
                sounds: library.items
            )
        }
        return initialCoverDescriptor
    }

    private var selectedPhotoArea: some View {
        JamSelectedPhotoAreaHost(
            visualTransport: visualTransport,
            assignments: session.slotAssignments,
            sounds: selectedSounds,
            imagesByID: selectedPhotoImagesByID,
            reduceMotion: reduceMotion,
            selectedJamRole: selectedJamRole,
            changePhotosButton: { changePhotosButton() },
            onTapRole: handleRoleTap,
            onDropPhotoID: handleTileDrop,
            onSwapForAccessibility: performSwapFromAccessibility
        )
    }

    private var sequencerAndStatus: some View {
        sequencerAndStatusContent
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named("jamViewport"))
            } action: { frame in
                jamSequencerFrame = frame
            }
    }

    private var sequencerAndStatusContent: some View {
        JamSequencerAndStatus(
            status: sequencerStatus,
            bpm: Int(jamBPM),
            sequencerContent: JamSequencerSnapshotHost(
                steps: jamStepsPerBar,
                session: session,
                visualTransport: visualTransport,
                roleColors: rowColorMap,
                reduceMotion: reduceMotion
            )
        )
        .frame(height: 150)
        .frame(maxWidth: .infinity)
    }

    private var sequencerStatus: JamSequencerStatus {
        let assignments = session.slotAssignments
        let region = JamGrooveLibrary.region(for: session.vibePosition)
        let drumKit = resolvedDrumKit(selection: session.drumKitSelection, region: region)

        return JamSequencerStatus(
            hasAnySelection: !assignments.allPhotoIDs.isEmpty,
            isPlaying: session.isPlaying,
            isApplyingNextBar: session.isPlaying && playbackController.hasPendingArrangementChanges,
            activeSlotCount: assignments.activePhotoIDs.count,
            reserveCount: assignments.reserve.count,
            region: region,
            drumKit: drumKit
        )
    }

    private var rowColorMap: [JamRole: Color] {
        var result: [JamRole: Color] = [:]
        for role in [JamRole.bass, .harmony, .melody] {
            if let color = photoColor(for: role) {
                result[role] = color
            }
        }
        return result
    }

    private func addPhotosButton(isLarge: Bool) -> some View {
        Button {
            isPhotoSelectorPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: isLarge ? 16 : 14, weight: .semibold))
                Text("Add Photos")
                    .font(
                        isLarge
                            ? .custom("ZTTalk-Bold", size: 17, relativeTo: .headline)
                            : .custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline)
                    )
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: isLarge ? 52 : 44)
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func changePhotosButton() -> some View {
        let backgroundFill: Color = colorScheme == .dark
            ? Color.secondary.opacity(0.12)
            : Color.black.opacity(0.08)
        let borderColor: Color = colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.10)

        return Button {
            isPhotoSelectorPresented = true
        } label: {
            HStack(spacing: 8) {
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
        .buttonStyle(.plain)
    }

    private var playbackButton: some View {
        Button {
            switch playbackAction {
            case .play:
                startPlaybackIfPossible()
            case .stop:
                clearTransportAndPlayback()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: playbackAction.systemImage)
                    .font(.headline.weight(.semibold))
                Text(playbackAction.title)
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
        .buttonStyle(.plain)
        .disabled(!canPlay)
    }

    private func confirmPhotoSelection(_ newSelectionIDs: [UUID]) {
        let stableSelection = newSelectionIDs.sorted { $0.uuidString < $1.uuidString }
        let validIDs = Set(library.items.map(\.id))
        let confirmedIDs = stableSelection.filter { validIDs.contains($0) }

        // Same selection (any order) is a no-op so a future manual slot
        // swap is not undone by re-running `assignRoles` when the user
        // simply re-confirms the same photos in the selector.
        guard Set(confirmedIDs) != Set(session.slotAssignments.allPhotoIDs) else { return }

        let resolvedSounds = confirmedIDs.compactMap { id in
            library.items.first(where: { $0.id == id })
        }
        let playableSounds = resolvedSounds.filter { !$0.sequence.notes.isEmpty }
        let playableIDs = Set(playableSounds.map(\.id))
        let confirmedIDSet = Set(confirmedIDs)
        let survivingActiveIDs = session.slotAssignments.activePhotoIDs.filter { confirmedIDSet.contains($0) }

        let newAssignments: JamSlotAssignments
        if session.slotAssignments.allPhotoIDs.isEmpty || survivingActiveIDs.isEmpty {
            let initialAssigned = arrangementBuilder.assignRoles(to: playableSounds)
            newAssignments = JamSlotAssignments(
                assignedSounds: initialAssigned,
                allSelectedIDs: confirmedIDs
            )
        } else {
            newAssignments = session.slotAssignments.reconcilingSelection(
                selectedIDs: confirmedIDs,
                playableIDs: playableIDs
            )
        }

        let previousAssignments = session.slotAssignments
        guard newAssignments != previousAssignments else { return }

        session.slotAssignments = newAssignments
        if session.isPlaying && newAssignments.hasDifferentActiveSlots(from: previousAssignments) {
            sendPendingArrangementToPlayer()
        }
    }

    private func handleTileDrop(droppedID: String, onto targetRole: JamRole?) {
        guard let targetRole,
              let parsedID = UUID(uuidString: droppedID),
              session.slotAssignments.activePhotoIDs.contains(parsedID) else {
            return
        }
        guard let sourceRole = session.slotAssignments.assignedRolesByID[parsedID] else {
            return
        }
        guard sourceRole != targetRole else { return }
        let source = sourceRole
        let destination = targetRole
        // Defer mutation to the next MainActor turn so the native drag session
        // can finish tearing down its source snapshot before we rebuild the slot.
        Task { @MainActor in
            await Task.yield()
            applySwap(source: source, destination: destination)
        }
    }

    private func performSwapFromAccessibility(source: JamRole, target: JamRole, photoID: UUID) {
        // Accessibility path has no native drag session, so no defer is needed.
        guard source != target,
              session.slotAssignments.photoID(for: source) == photoID else { return }
        applySwap(source: source, destination: target)
    }

    private func applySwap(source: JamRole, destination: JamRole) {
        guard source != destination else { return }
        let next = session.slotAssignments.swapping(source, destination)
        guard next != session.slotAssignments else { return }

        withAnimation(photoSwapAnimation) {
            session.slotAssignments = next
        }

        if session.isPlaying {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                sendPendingArrangementToPlayer()
            }
        }

        swapArrangementVersion += 1
    }

    private func selectDrumKit(_ selection: MusicDrumKitSelection) {
        guard selection != session.drumKitSelection else { return }
        session.drumKitSelection = selection

        guard session.isPlaying else {
            playbackController.clearDrumKitPendingFeedback()
            return
        }

        playbackController.beginDrumKitPendingFeedback(reduceMotion: reduceMotion)
        sendPendingArrangementToPlayer()
    }

    private func handleRoleTap(_ role: JamRole?) {
        guard let role else { return }

        if selectedJamRole == role {
            selectedJamRole = nil
            if selectedPanel == .arrange {
                closePanel()
            }
            return
        }

        let previousRole = selectedJamRole
        selectedJamRole = role
        if previousRole != role {
            syncArrangeDraft(for: role)
            if selectedPanel == .arrange {
                closePanel()
            }
        }
        if selectedPanel == .arrange && !canOpenArrangePanel {
            closePanel()
        }
    }

    private var displayedReferenceArrangement: JamArrangement? {
        playbackController.pendingArrangement ?? session.activeArrangement
    }

    private var canOpenArrangePanel: Bool {
        guard let selectedJamRole else { return false }
        return isRolePlayable(selectedJamRole)
    }

    private func isRolePlayable(_ role: JamRole) -> Bool {
        guard let roleID = session.slotAssignments.photoID(for: role),
              let sound = library.items.first(where: { $0.id == roleID }) else {
            return false
        }
        return !sound.sequence.notes.isEmpty
    }

    private var selectedArrangePhotoID: UUID? {
        guard let selectedJamRole else { return nil }
        return session.slotAssignments.photoID(for: selectedJamRole)
    }

    private var selectedArrangeSound: PhotoSound? {
        guard let selectedArrangePhotoID else { return nil }
        return library.items.first(where: { $0.id == selectedArrangePhotoID })
    }

    private var arrangeAvailability: JamArrangeAvailability {
        guard let selectedJamRole else { return .noRoleSelected }
        guard selectedArrangePhotoID != nil else {
            return .roleHasNoPhoto(selectedJamRole)
        }
        guard let sound = selectedArrangeSound else {
            return .missingPhoto(selectedJamRole)
        }
        guard !sound.sequence.notes.isEmpty else {
            return .roleHasNoMusicalMaterial(selectedJamRole)
        }
        return .available(selectedJamRole)
    }

    private var arrangePanelContext: JamArrangePanelContext {
        guard let role = selectedJamRole else {
            return JamArrangePanelContext(
                role: nil,
                title: "ARRANGE",
                subtitle: "Select a playable photo",
                options: [],
                selectedOption: nil,
                buttonTitle: "NEW PATTERN",
                isActionEnabled: false
            )
        }

        switch role {
        case .bass:
            return JamArrangePanelContext(
                role: .bass,
                title: "BASS",
                subtitle: "Shape the low-end pattern",
                options: BassPatternIntent.allCases.map { .bass($0) },
                selectedOption: .bass(selectedBassIntent),
                buttonTitle: "NEW PATTERN",
                isActionEnabled: canOpenArrangePanel
            )
        case .harmony:
            return JamArrangePanelContext(
                role: .harmony,
                title: "HARMONY",
                subtitle: "Shape the harmonic rhythm",
                options: HarmonyPatternIntent.allCases.map { .harmony($0) },
                selectedOption: .harmony(selectedHarmonyIntent),
                buttonTitle: "NEW PATTERN",
                isActionEnabled: canOpenArrangePanel
            )
        case .melody:
            return JamArrangePanelContext(
                role: .melody,
                title: "MELODY",
                subtitle: "Shape the next phrase",
                options: MelodyPhraseIntent.allCases.map { .melody($0) },
                selectedOption: .melody(selectedMelodyIntent),
                buttonTitle: "NEW PHRASE",
                isActionEnabled: canOpenArrangePanel
            )
        }
    }

    private func syncAllArrangeDrafts() {
        syncArrangeDraft(for: .bass)
        syncArrangeDraft(for: .harmony)
        syncArrangeDraft(for: .melody)
    }

    private func syncArrangeDraft(for role: JamRole) {
        switch role {
        case .bass:
            selectedBassIntent = session.bassVariation.intent ?? .steady
        case .harmony:
            selectedHarmonyIntent = session.harmonyVariation.intent ?? .sustained
        case .melody:
            selectedMelodyIntent = .subtle
        }
    }

    private func updateArrangeDraft(_ option: JamArrangeOption) {
        switch option {
        case .bass(let intent):
            selectedBassIntent = intent
        case .harmony(let intent):
            selectedHarmonyIntent = intent
        case .melody(let intent):
            selectedMelodyIntent = intent
        }
    }

    private func applySelectedArrangeVariation() {
        guard let selectedJamRole else { return }

        switch selectedJamRole {
        case .bass:
            applyNextBassPattern(intent: selectedBassIntent)
        case .harmony:
            applyNextHarmonyPattern(intent: selectedHarmonyIntent)
        case .melody:
            applyNextMelodyPhrase(intent: selectedMelodyIntent)
        }
    }

    private func applyNextBassPattern(intent: BassPatternIntent) {
        guard isRolePlayable(.bass) else { return }
        session.bassVariation = JamBassVariation(
            generation: session.bassVariation.generation &+ 1,
            intent: intent
        )
        scheduleAutosave()

        if session.isPlaying {
            sendPendingArrangementToPlayer()
        } else {
            session.activeArrangement = buildArrangement()
        }
    }

    private func applyNextHarmonyPattern(intent: HarmonyPatternIntent) {
        guard isRolePlayable(.harmony) else { return }
        session.harmonyVariation = JamHarmonyVariation(
            generation: session.harmonyVariation.generation &+ 1,
            intent: intent
        )
        scheduleAutosave()

        if session.isPlaying {
            sendPendingArrangementToPlayer()
        } else {
            session.activeArrangement = buildArrangement()
        }
    }

    private func applyNextMelodyPhrase(intent: MelodyPhraseIntent) {
        guard isRolePlayable(.melody),
              let result = findNextMelodyVariation(
                after: session.melodyVariation,
                intent: intent,
                referenceArrangement: displayedReferenceArrangement,
                buildArrangement: { assignments, bassVariation, harmonyVariation, variation, mode in
                    buildArrangement(
                        for: assignments,
                        bassVariation: bassVariation,
                        harmonyVariation: harmonyVariation,
                        melodyVariation: variation,
                        buildMode: mode
                    )
                }
              ) else {
            return
        }

        session.melodyVariation = result.variation
        scheduleAutosave()

        if session.isPlaying {
            if result.usedFallback {
                playbackController.beginPendingArrangement(
                    result.arrangement,
                    loopIteration: library.currentJamTransportSnapshot()?.loopIteration
                )
                library.updateTransientLoop(
                    sequence: result.arrangement.sequence,
                    percussion: result.arrangement.percussion
                )
            } else {
                sendPendingArrangementToPlayer()
            }
        } else {
            session.activeArrangement = result.arrangement
        }
    }

    private func startPlaybackIfPossible() {
        cancelTransportTask()

        guard let arrangement = buildArrangement() else {
            return
        }

        session.activeArrangement = arrangement
        library.playTransientSequence(
            arrangement.sequence,
            percussion: arrangement.percussion,
            loops: true
        )
        // Forward the current Effect Rack settings to the dedicated Jam chain.
        library.setJamEffects(session.effectSettings, bpm: Double(arrangement.sequence.harmony.bpm))
        // Do not seed `currentStep` to 0 here. The transport polling task will
        // read the real sample position from the AVAudioPlayerNode and
        // surface the first valid step. Until then the sequencer shows nil.
        visualTransport.reset()
        session.isPlaying = true
        playbackController.clearDrumKitPendingFeedback()
        playbackController.clearPendingState()
        startTransportLoop()
    }

    /// Sends the latest arrangement to the MusicPlayer immediately so it can
    /// debounce, render, and prepare the next loop buffer. The arrangement
    /// stays pending inside `JamPlaybackController` until the real audio
    /// boundary promotes it.
    private func sendPendingArrangementToPlayer() {
        guard session.isPlaying else { return }
        guard let arrangement = buildArrangement() else {
            // Nothing playable: drop the pending state instead of hanging on it.
            playbackController.clearPendingState()
            return
        }

        playbackController.beginPendingArrangement(
            arrangement,
            loopIteration: library.currentJamTransportSnapshot()?.loopIteration
        )

        library.updateTransientLoop(
            sequence: arrangement.sequence,
            percussion: arrangement.percussion
        )
    }

    private func clearTransportAndPlayback(clearPending: Bool = true) {
        cancelTransportTask()
        playbackController.clearDrumKitPendingFeedback()
        library.stopTransientPlayback()
        session.activeArrangement = nil
        visualTransport.reset()
        session.isPlaying = false
        if clearPending {
            playbackController.clearPendingState()
        }
    }

    /// Clears only the Jam's local transport/UI state.
    /// Use when the underlying player has already been stopped
    /// externally (e.g. audio interruption) and we must not call `player.stop()` again.
    private func clearTransportState() {
        cancelTransportTask()
        playbackController.clearDrumKitPendingFeedback()
        session.activeArrangement = nil
        visualTransport.reset()
        session.isPlaying = false
        playbackController.clearPendingState()
    }

    private func cancelTransportTask() {
        transportTask?.cancel()
        transportTask = nil
    }

    private func startTransportLoop() {
        cancelTransportTask()

        transportTask = Task { @MainActor in
            // UI polling task. The musical clock is the AVAudioPlayerNode
            // sample position; this loop just asks the player for it.
            while !Task.isCancelled && session.isPlaying {
                try? await Task.sleep(for: transportPollInterval)
                guard !Task.isCancelled, session.isPlaying else { break }

                pollTransportFromPlayer()
            }
        }
    }

    /// Reads the current transport position from the MusicPlayer and applies
    /// the smallest possible UI update. Skips all work if the step or
    /// active-sound set did not change since the last poll.
    private func pollTransportFromPlayer() {
        guard let snapshot = library.currentJamTransportSnapshot() else {
            // Player is not yet producing a valid position. Preserve nil UI.
            return
        }

        let step = snapshot.currentStep
        if let pending = playbackController.promotePendingArrangementIfNeeded(from: snapshot) {
            // Promote the pending arrangement on the real audio boundary.
            // The sequencer and the audio are now in sync.
            session.activeArrangement = pending
            updateStepState(step: step, arrangement: pending)
            return
        }

        let activeIDs = Set(
            session.activeArrangement?.activeStepsBySoundID.compactMap { soundID, steps in
                steps.contains(step) ? soundID : nil
            } ?? []
        )

        // No promotion this poll; just keep the UI in step with the audio.
        visualTransport.update(step: step, activeSoundIDs: activeIDs)
    }

    private func updateStepState(step: Int, arrangement: JamArrangement) {
        let activeIDs = Set(
            arrangement.activeStepsBySoundID.compactMap { soundID, steps in
                steps.contains(step) ? soundID : nil
            }
        )

        visualTransport.update(step: step, activeSoundIDs: activeIDs)
    }

    private func buildArrangement() -> JamArrangement? {
        buildArrangement(
            for: session.slotAssignments,
            bassVariation: session.bassVariation,
            harmonyVariation: session.harmonyVariation,
            melodyVariation: session.melodyVariation,
            buildMode: .standard
        )
    }

    private func buildArrangement(
        for assignments: JamSlotAssignments,
        bassVariation: JamBassVariation,
        harmonyVariation: JamHarmonyVariation,
        melodyVariation: JamMelodyVariation,
        buildMode: MelodyVariationBuildMode
    ) -> JamArrangement? {
        let roleByID = assignments.assignedRolesByID
        let playableAssignedSounds = library.items.compactMap { sound -> AssignedSound? in
            guard !sound.sequence.notes.isEmpty,
                  let role = roleByID[sound.id] else {
                return nil
            }
            return AssignedSound(sound: sound, role: role)
        }
        let orderedRoles: [JamRole] = [.bass, .harmony, .melody]
        let orderedAssignedSounds = orderedRoles.compactMap { role in
            playableAssignedSounds.first { $0.role == role }
        }
        let region = JamGrooveLibrary.region(for: session.vibePosition)
        let drumKit = resolvedDrumKit(selection: session.drumKitSelection, region: region)

        return arrangementBuilder.build(
            assignedSounds: orderedAssignedSounds,
            vibePosition: session.vibePosition,
            drumKit: drumKit,
            bassVariation: bassVariation,
            harmonyVariation: harmonyVariation,
            melodyVariation: melodyVariation,
            buildMode: buildMode
        )
    }

    private func synchronizeSelectionState(
        previousAssignments: JamSlotAssignments,
        newAssignments: JamSlotAssignments
    ) {
        if let selectedJamRole,
           newAssignments.photoID(for: selectedJamRole) == nil {
            self.selectedJamRole = nil
        }

        if selectedPanel == .arrange && !canOpenArrangePanel {
            closePanel()
        }
    }

    private func findNextMelodyVariation(
        after currentVariation: JamMelodyVariation,
        intent: MelodyPhraseIntent,
        referenceArrangement: JamArrangement?,
        buildArrangement: (JamSlotAssignments, JamBassVariation, JamHarmonyVariation, JamMelodyVariation, MelodyVariationBuildMode) -> JamArrangement?
    ) -> MelodyVariationSearchResult? {
        let referenceSequence = referenceArrangement?.sequence
        let prioritizedAttempts = prioritizedVariationAttempts(after: currentVariation, intent: intent)
        var bestAccepted: (result: MelodyVariationSearchResult, fitness: Double)?
        var bestAcceptedBelowThreshold: (result: MelodyVariationSearchResult, fitness: Double)?
        var bestOverall: (result: MelodyVariationSearchResult, fitness: Double)?

        for attempt in prioritizedAttempts {
            let variation = JamMelodyVariation(generation: currentVariation.generation &+ UInt64(attempt))
            let family = MelodyVariationFamily(generation: variation.generation)
            guard let arrangement = buildArrangement(
                session.slotAssignments,
                session.bassVariation,
                session.harmonyVariation,
                variation,
                .standard
            ) else { continue }

            let difference = referenceSequence.map {
                melodyDifference(from: $0, to: arrangement.sequence)
            } ?? MelodyDifference.identityFallback
            let comparableEventCount = max(
                difference.previousOccupiedStepCount,
                difference.candidateOccupiedStepCount
            )
            let minimumChangedSteps = minimumChangedSteps(for: comparableEventCount)
            let meetsGeneralMinimum = difference.changedSteps >= minimumChangedSteps
            let meetsFamilyMinimum = meetsFamilyRequirement(
                family,
                difference: difference,
                comparableEventCount: comparableEventCount
            )
            let meetsThreshold = difference.score >= melodyDistanceThreshold
            let accepted = meetsGeneralMinimum && meetsFamilyMinimum && meetsThreshold
            let fitness = melodyIntentFitness(
                for: intent,
                family: family,
                difference: difference,
                referenceSequence: referenceSequence,
                candidateSequence: arrangement.sequence,
                usedFallback: false
            )

            let result = MelodyVariationSearchResult(
                variation: variation,
                arrangement: arrangement,
                family: family,
                difference: difference,
                minimumChangedSteps: minimumChangedSteps,
                accepted: accepted,
                usedFallback: false
            )

#if DEBUG
            print(melodyVariationLog(for: result))
#endif

            if accepted {
                if let existingBestAccepted = bestAccepted {
                    if fitness > existingBestAccepted.fitness {
                        bestAccepted = (result, fitness)
                    }
                } else {
                    bestAccepted = (result, fitness)
                }
            }

            if meetsGeneralMinimum && meetsFamilyMinimum {
                if let existingBestAccepted = bestAcceptedBelowThreshold {
                    if fitness > existingBestAccepted.fitness {
                        bestAcceptedBelowThreshold = (result, fitness)
                    }
                } else {
                    bestAcceptedBelowThreshold = (result, fitness)
                }
            }

            if let existingBestOverall = bestOverall {
                if fitness > existingBestOverall.fitness {
                    bestOverall = (result, fitness)
                }
            } else {
                bestOverall = (result, fitness)
            }
        }

        if let bestAccepted {
            return bestAccepted.result
        }

        if let bestAcceptedBelowThreshold {
            return bestAcceptedBelowThreshold.result
        }

        guard let bestOverall,
              let fallbackArrangement = buildArrangement(
                session.slotAssignments,
                session.bassVariation,
                session.harmonyVariation,
                bestOverall.result.variation,
                .fallback
              ) else {
            return nil
        }

        let fallbackDifference = referenceSequence.map {
            melodyDifference(from: $0, to: fallbackArrangement.sequence)
        } ?? MelodyDifference.identityFallback
        let comparableEventCount = max(
            fallbackDifference.previousOccupiedStepCount,
            fallbackDifference.candidateOccupiedStepCount
        )
        let minimumChangedSteps = minimumChangedSteps(for: comparableEventCount)
        let meetsGeneralMinimum = fallbackDifference.changedSteps >= minimumChangedSteps
        let meetsFamilyMinimum = meetsFamilyRequirement(
            bestOverall.result.family,
            difference: fallbackDifference,
            comparableEventCount: comparableEventCount
        )
        let accepted = meetsGeneralMinimum && meetsFamilyMinimum && fallbackDifference.score >= melodyDistanceThreshold

        let fallbackResult = MelodyVariationSearchResult(
            variation: bestOverall.result.variation,
            arrangement: fallbackArrangement,
            family: bestOverall.result.family,
            difference: fallbackDifference,
            minimumChangedSteps: minimumChangedSteps,
            accepted: accepted,
            usedFallback: true
        )

#if DEBUG
        print(melodyVariationLog(for: fallbackResult))
#endif

        return fallbackResult.accepted ? fallbackResult : nil
    }

    private func prioritizedVariationAttempts(
        after currentVariation: JamMelodyVariation,
        intent: MelodyPhraseIntent
    ) -> [Int] {
        let familyPriority = Dictionary(
            uniqueKeysWithValues: intent.preferredFamilies.enumerated().map { ($1, $0) }
        )

        return Array(1...8).sorted { lhs, rhs in
            let lhsFamily = MelodyVariationFamily(generation: currentVariation.generation &+ UInt64(lhs))
            let rhsFamily = MelodyVariationFamily(generation: currentVariation.generation &+ UInt64(rhs))
            let lhsPriority = familyPriority[lhsFamily] ?? Int.max
            let rhsPriority = familyPriority[rhsFamily] ?? Int.max

            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs < rhs
        }
    }

    private func melodyIntentFitness(
        for intent: MelodyPhraseIntent,
        family: MelodyVariationFamily,
        difference: MelodyDifference,
        referenceSequence: MusicSequence?,
        candidateSequence: MusicSequence,
        usedFallback: Bool
    ) -> Double {
        let previousEventCount = referenceSequence.map { melodyStepProfile(for: $0).count } ?? 0
        let candidateEventCount = melodyStepProfile(for: candidateSequence).count
        let eventDelta = candidateEventCount - previousEventCount
        let registerLift = referenceSequence.map {
            melodyAverageRepresentativePitch(for: candidateSequence) - melodyAverageRepresentativePitch(for: $0)
        } ?? 0
        let familyBonus = intent.preferredFamilies.contains(family)
            ? Double(intent.preferredFamilies.count - (intent.preferredFamilies.firstIndex(of: family) ?? 0)) * 0.05
            : 0

        let intentScore: Double
        switch intent {
        case .subtle:
            intentScore =
                (1 - difference.changedStepRatio) * 0.34
                + (1 - clampedUnit(Double(max(difference.changedPresenceSteps - 1, 0)) / 4.0)) * 0.26
                + difference.contourDistance * 0.18
                + difference.registerDistance * 0.14
                + (eventDelta == 0 ? 0.08 : 0)
        case .energetic:
            intentScore =
                difference.changedStepRatio * 0.28
                + clampedUnit(Double(max(eventDelta, 0)) / 3.0) * 0.24
                + clampedUnit(Double(max(registerLift, 0)) / 12.0) * 0.18
                + (difference.changedPresenceSteps > 0 ? 0.14 : 0)
                + difference.contourDistance * 0.08
        case .sparse:
            intentScore =
                clampedUnit(Double(max(previousEventCount - candidateEventCount, 0)) / 3.0) * 0.32
                + (difference.changedPresenceSteps > 0 ? 0.22 : 0)
                + (candidateEventCount > 0 ? 0.16 : -1)
                + (eventDelta <= 0 ? 0.14 : 0)
                + difference.registerDistance * 0.08
        case .surprise:
            intentScore =
                difference.score * 0.30
                + difference.changedStepRatio * 0.26
                + difference.registerDistance * 0.16
                + difference.contourDistance * 0.12
                + clampedUnit(Double(abs(eventDelta)) / 4.0) * 0.10
        }

        return intentScore + familyBonus - (usedFallback ? 0.08 : 0)
    }

    private func sendCurrentArrangementToPlayer() {
        guard let arrangement = buildArrangement() else {
            playbackController.clearDrumKitPendingFeedback()
            clearTransportAndPlayback()
            return
        }

        playbackController.clearPendingState()
        playbackController.clearDrumKitPendingFeedback()
        session.activeArrangement = arrangement

        library.playTransientSequence(
            arrangement.sequence,
            percussion: arrangement.percussion,
            loops: true
        )
    }

    private func resolvedDrumKit(
        selection: MusicDrumKitSelection,
        region: JamRegion
    ) -> MusicDrumKit {
        switch selection {
        case .auto:
            switch region {
            case .airy: .soft
            case .bright: .club
            case .deep: .breakbeat
            case .intense: .metal
            }
        case .soft: .soft
        case .club: .club
        case .breakbeat: .breakbeat
        case .metal: .metal
        }
    }
}

private let melodyDistanceThreshold = 0.34

private struct MelodyVariationSearchResult {
    let variation: JamMelodyVariation
    let arrangement: JamArrangement
    let family: MelodyVariationFamily
    let difference: MelodyDifference
    let minimumChangedSteps: Int
    let accepted: Bool
    let usedFallback: Bool
}

private struct MelodyStepProfile {
    let pitches: [Int]

    var representativePitch: Int {
        pitches.first ?? 0
    }
}

private struct MelodyDifference {
    let previousOccupiedStepCount: Int
    let candidateOccupiedStepCount: Int
    let changedPresenceSteps: Int
    let changedPitchSteps: Int
    let changedSteps: Int
    let changedStepRatio: Double
    let contourDistance: Double
    let registerDistance: Double
    let score: Double

    static let identityFallback = MelodyDifference(
        previousOccupiedStepCount: 0,
        candidateOccupiedStepCount: 0,
        changedPresenceSteps: 0,
        changedPitchSteps: 0,
        changedSteps: 0,
        changedStepRatio: 1,
        contourDistance: 1,
        registerDistance: 1,
        score: 1
    )
}

private func melodyDifference(
    from previous: MusicSequence,
    to candidate: MusicSequence
) -> MelodyDifference {
    let previousProfile = melodyStepProfile(for: previous)
    let candidateProfile = melodyStepProfile(for: candidate)
    let allSteps = Set(previousProfile.keys).union(candidateProfile.keys)
    let sharedSteps = allSteps.filter { previousProfile[$0] != nil && candidateProfile[$0] != nil }.sorted()
    let changedPresenceSteps = allSteps.filter { (previousProfile[$0] != nil) != (candidateProfile[$0] != nil) }.count
    let changedPitchSteps = sharedSteps.filter { previousProfile[$0]?.pitches != candidateProfile[$0]?.pitches }.count
    let changedSteps = Set(
        allSteps.filter { (previousProfile[$0] != nil) != (candidateProfile[$0] != nil) }
            + sharedSteps.filter { previousProfile[$0]?.pitches != candidateProfile[$0]?.pitches }
    ).count

    let comparableEventCount = max(previousProfile.count, candidateProfile.count)
    let changedStepRatio = comparableEventCount == 0
        ? 0
        : clampedUnit(Double(changedSteps) / Double(comparableEventCount))

    let registerDistance: Double
    if sharedSteps.isEmpty {
        registerDistance = changedStepRatio
    } else {
        let total = sharedSteps.reduce(0.0) { partial, step in
            let lhs = previousProfile[step]?.representativePitch ?? 0
            let rhs = candidateProfile[step]?.representativePitch ?? 0
            return partial + clampedUnit(Double(abs(lhs - rhs)) / 12.0)
        }
        registerDistance = clampedUnit(total / Double(sharedSteps.count))
    }

    let previousIntervals = melodyIntervals(from: previousProfile, orderedSteps: sharedSteps)
    let candidateIntervals = melodyIntervals(from: candidateProfile, orderedSteps: sharedSteps)
    let contourDistance: Double
    if previousIntervals.isEmpty || candidateIntervals.isEmpty {
        contourDistance = 0
    } else {
        let pairCount = min(previousIntervals.count, candidateIntervals.count)
        let changed = zip(previousIntervals.prefix(pairCount), candidateIntervals.prefix(pairCount)).filter { $0 != $1 }.count
        contourDistance = clampedUnit(Double(changed) / Double(pairCount))
    }

    let score = clampedUnit(
        changedStepRatio * 0.55
            + contourDistance * 0.25
            + registerDistance * 0.20
    )

    return MelodyDifference(
        previousOccupiedStepCount: previousProfile.count,
        candidateOccupiedStepCount: candidateProfile.count,
        changedPresenceSteps: changedPresenceSteps,
        changedPitchSteps: changedPitchSteps,
        changedSteps: changedSteps,
        changedStepRatio: changedStepRatio,
        contourDistance: contourDistance,
        registerDistance: registerDistance,
        score: score
    )
}

private func melodyStepProfile(for sequence: MusicSequence) -> [Int: MelodyStepProfile] {
    let melodyNotes = sequence.notes
        .filter { $0.voiceRole == .melody }
        .sorted {
            if $0.step != $1.step { return $0.step < $1.step }
            if $0.midiNote != $1.midiNote { return $0.midiNote < $1.midiNote }
            return $0.row < $1.row
        }

    let grouped = Dictionary(grouping: melodyNotes, by: \.step)
    var profile: [Int: MelodyStepProfile] = [:]
    for (step, notes) in grouped {
        profile[step] = MelodyStepProfile(pitches: notes.map(\.midiNote).sorted())
    }
    return profile
}

private func melodyAverageRepresentativePitch(for sequence: MusicSequence) -> Double {
    let profile = melodyStepProfile(for: sequence)
    guard !profile.isEmpty else { return 0 }
    let total = profile.values.reduce(0.0) { partial, step in
        partial + Double(step.representativePitch)
    }
    return total / Double(profile.count)
}

private func melodyIntervals(
    from profile: [Int: MelodyStepProfile],
    orderedSteps: [Int]
) -> [Int] {
    let pitches = orderedSteps.compactMap { profile[$0]?.representativePitch }
    guard pitches.count >= 2 else { return [] }
    return zip(pitches, pitches.dropFirst()).map { current, next in
        let interval = next - current
        if interval == 0 { return 0 }
        return interval > 0 ? 1 : -1
    }
}

private func clampedUnit(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func minimumChangedSteps(for comparableEventCount: Int) -> Int {
    switch comparableEventCount {
    case 0: 0
    case 1: 1
    case 2: 1
    case 3: 2
    default:
        max(2, Int(ceil(Double(comparableEventCount) * 0.40)))
    }
}

private func meetsFamilyRequirement(
    _ family: MelodyVariationFamily,
    difference: MelodyDifference,
    comparableEventCount: Int
) -> Bool {
    switch family {
    case .rhythm:
        if comparableEventCount < 4 {
            return difference.changedSteps >= minimumChangedSteps(for: comparableEventCount)
        }
        return difference.changedPresenceSteps >= min(
            comparableEventCount,
            max(2, Int(ceil(Double(comparableEventCount) * 0.35)))
        )

    case .contour:
        if comparableEventCount < 4 {
            return difference.changedPitchSteps >= max(1, minimumChangedSteps(for: comparableEventCount) - 1)
        }
        return difference.changedPitchSteps >= min(
            comparableEventCount,
            max(2, Int(ceil(Double(comparableEventCount) * 0.40)))
        )

    case .register:
        if comparableEventCount < 4 {
            return difference.changedPitchSteps >= max(1, minimumChangedSteps(for: comparableEventCount) - 1)
        }
        let requiredPitchChanges = comparableEventCount >= 6 ? 3 : 2
        return difference.changedPitchSteps >= min(requiredPitchChanges, comparableEventCount)

    case .full:
        if comparableEventCount < 4 {
            return difference.changedSteps >= minimumChangedSteps(for: comparableEventCount)
        }
        return difference.changedSteps >= min(
            comparableEventCount,
            Int(ceil(Double(comparableEventCount) * 0.50))
        )
    }
}

#if DEBUG
private func melodyVariationLog(for result: MelodyVariationSearchResult) -> String {
    """
    [MelodyVariation]
    generation: \(result.variation.generation)
    family: \(result.family.logLabel)
    previous events: \(result.difference.previousOccupiedStepCount)
    candidate events: \(result.difference.candidateOccupiedStepCount)
    changed presence: \(result.difference.changedPresenceSteps)
    changed pitch: \(result.difference.changedPitchSteps)
    changed total: \(result.difference.changedSteps)
    ratio: \(String(format: "%.3f", result.difference.changedStepRatio))
    contour: \(String(format: "%.3f", result.difference.contourDistance))
    register: \(String(format: "%.3f", result.difference.registerDistance))
    score: \(String(format: "%.3f", result.difference.score))
    minimum required: \(result.minimumChangedSteps)
    fallback: \(result.usedFallback)
    accepted: \(result.accepted)
    """
}
#endif

private enum JamPersistenceError: Equatable {
    case notFound
    case corruptedFile(UUID)
    case unsupportedSchemaVersion(Int)
    case writeFailed
}

enum PlaybackAction: Equatable {
    case play
    case stop

    var title: String {
        switch self {
        case .play: "Play"
        case .stop: "Stop"
        }
    }

    var systemImage: String {
        switch self {
        case .play: "play.fill"
        case .stop: "stop.fill"
        }
    }
}

extension Color {
    init(jamRGB rgb: RGBColor) {
        self.init(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}
