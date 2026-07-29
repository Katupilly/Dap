import SwiftUI
import UIKit
import OSLog

private let jamStepsPerBar = MusicSequence.steps
private let jamBPM = 96.0

struct JamView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
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
    @State private var selectedMelodyIntent: MelodyPhraseIntent = .subtle
    @State private var playbackController = JamPlaybackController()
    @State private var isPhotoSelectorPresented = false
    @State private var swapArrangementVersion = 0
    @State private var transportTask: Task<Void, Never>?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var persistenceError: JamPersistenceError?
    @State private var hasAppliedInitialJam = false

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
        return Color(RetroCoverRenderer.tonalPalette(for: pitch).base)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemBackground)

            GeometryReader { geometry in
                ViewThatFits(in: .vertical) {
                    fixedSessionLayout
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    ScrollView {
                        sessionContentStack
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .blur(radius: isPanelPresented ? 2.5 : 0)
            .animation(.easeInOut(duration: 0.18), value: isPanelPresented)

            if isPanelPresented {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closePanel()
                    }
                    .zIndex(1)
            }

            if hasAnySelection {
                panelLayer
                    .zIndex(3)

                JamDockBar(
                    selectedPanel: $selectedPanel,
                    isPanelPresented: $isPanelPresented,
                    session: session,
                    selectedJamRole: selectedJamRole,
                    canOpenArrangePanel: canOpenArrangePanel,
                    onPanelToggle: { target in
                        handlePanelToggle(target)
                    }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 82)
                .zIndex(4)

                playbackButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .zIndex(5)
            }
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
                    melodyVariation: session.melodyVariation,
                    buildMode: .standard
                )
            }
            synchronizeSelectionState(previousAssignments: oldAssignments, newAssignments: assignments)
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
            synchronizeSelectionState(previousAssignments: session.slotAssignments, newAssignments: session.slotAssignments)
        }
        .onDisappear {
            library.clearTransientLoopUpdatePreparedHandler()
            Task { await flushAutosave() }
            clearTransportAndPlayback()
            selectedJamRole = nil
            selectedPanel = .none
            isPanelPresented = false
        }
        .onChange(of: isActive) { _, isActive in
            guard !isActive else { return }
            Task { await flushAutosave() }
            clearTransportAndPlayback()
            selectedJamRole = nil
            selectedPanel = .none
            isPanelPresented = false
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
                    melodyVariation: session.melodyVariation,
                    buildMode: .standard
                )
            }

            session.slotAssignments = cleanedAssignments
            synchronizeSelectionState(previousAssignments: previousAssignments, newAssignments: cleanedAssignments)
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
        session.melodyVariation = jam.melodyVariation ?? .initial
        session.isPlaying = false
        visualTransport.reset()
        playbackController.clearPendingState()
        playbackController.clearDrumKitPendingFeedback()
        selectedPanel = .none
        isPanelPresented = false
        selectedJamRole = nil

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
        session.activeArrangement = buildArrangement(
            for: reconciledAssignments,
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
            melodyVariation: session.melodyVariation
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
            || snapshot.melodyVariation != (jam.melodyVariation ?? .initial)
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

    @ViewBuilder
    private var panelLayer: some View {
        if isPanelPresented || selectedPanel != .none {
            let size = panelSize(for: selectedPanel)
            ZStack(alignment: .bottom) {
                panelContent
                    .scaleEffect(isPanelPresented ? 1 : 0.97, anchor: .bottom)
                    .opacity(isPanelPresented ? 1 : 0)
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity)
            .padding(.bottom, dockBottomInset + dockHeight + panelDockGap)
            .animation(panelSizeAnimation, value: selectedPanel)
        }
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
        JamVibePanelContent(
            session: session,
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
        JamArrangePanel(
            role: selectedJamRole,
            selectedIntent: selectedMelodyIntent,
            isMelodyActionEnabled: isMelodyArrangeAvailable,
            fill: expandedPanelFill,
            stroke: expandedPanelStroke,
            onSelectIntent: { selectedMelodyIntent = $0 },
            onApply: {
                applyNextMelodyPhrase(intent: selectedMelodyIntent)
            }
        )
    }

    private var arrangePanelSize: CGSize {
        switch selectedJamRole {
        case .bass, .harmony:
            return CGSize(width: 320, height: 188)
        case .melody:
            return CGSize(width: 320, height: 316)
        case .none:
            return CGSize(width: 320, height: 188)
        }
    }

    private var kitsPanelContent: some View {
        let width = panelSize(for: .kits).width
        let height = panelSize(for: .kits).height

        return VStack(alignment: .leading, spacing: 0) {
            kitsHeader
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(MusicDrumKitSelection.allCases, id: \.self) { selection in
                    drumKitOptionButton(selection)
                }
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 18)
        .frame(width: width, height: height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: effectsPanelCornerRadius, style: .continuous)
                .fill(expandedPanelFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: effectsPanelCornerRadius, style: .continuous)
                .stroke(expandedPanelStroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kits")
    }

    private var kitsHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Drum Kits")
                .font(.custom("ZTTalk-Bold", size: 20, relativeTo: .title3))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(currentDrumKitSubtitle)
                .font(.custom("ZTTalk-Medium", size: 12, relativeTo: .caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func drumKitOptionButton(_ selection: MusicDrumKitSelection) -> some View {
        let isSelected = session.drumKitSelection == selection
        let detailText: String? = if isSelected && playbackController.isDrumKitChangePending {
            playbackController.isPreparedDrumKitChangePending ? "Queued" : "Next bar"
        } else {
            nil
        }

        return Button {
            selectDrumKit(selection)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.displayName)
                        .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let detailText {
                        Text(detailText)
                            .font(.custom("ZTTalk-Medium", size: 12, relativeTo: .caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(" ")
                            .font(.custom("ZTTalk-Medium", size: 12, relativeTo: .caption))
                    }
                }

                Spacer(minLength: 8)

                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.10) : Color.clear)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isSelected
                                ? Color.primary.opacity(colorScheme == .dark ? 0.45 : 0.24)
                                : expandedPanelStroke,
                            lineWidth: 1
                        )

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected
                            ? Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.14)
                            : expandedPanelStroke,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selection.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var effectsPanelContent: some View {
        let width = panelSize(for: .effects).width
        let height = panelSize(for: .effects).height
        let activeCount = activeEffectsCount

        return VStack(alignment: .leading, spacing: 0) {
            effectsHeader(activeCount: activeCount)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            effectRow(
                systemImage: "water.waves",
                title: "Reverb",
                description: "Medium Hall",
                isEnabled: Binding(
                    get: { session.effectSettings.reverbEnabled },
                    set: { session.effectSettings.reverbEnabled = $0 }
                ),
                mixValue: Binding(
                    get: { Double(session.effectSettings.reverbMix) },
                    set: { session.effectSettings.reverbMix = Float($0) }
                ),
                enableLabel: "Reverb",
                mixLabel: "Reverb Mix"
            )
            .padding(.horizontal, 18)

            effectDivider
                .padding(.horizontal, 18)

            effectRow(
                systemImage: "repeat",
                title: "Delay",
                description: "Dotted 1/8",
                isEnabled: Binding(
                    get: { session.effectSettings.delayEnabled },
                    set: { session.effectSettings.delayEnabled = $0 }
                ),
                mixValue: Binding(
                    get: { Double(session.effectSettings.delayMix) },
                    set: { session.effectSettings.delayMix = Float($0) }
                ),
                enableLabel: "Delay",
                mixLabel: "Delay Mix"
            )
            .padding(.horizontal, 18)

            effectRow(
                systemImage: "waveform.path",
                title: "LFO",
                description: "Tremolo · 1/2",
                isEnabled: Binding(
                    get: { session.effectSettings.lfoEnabled },
                    set: { session.effectSettings.lfoEnabled = $0 }
                ),
                mixValue: Binding(
                    get: { Double(session.effectSettings.lfoAmount) },
                    set: { session.effectSettings.lfoAmount = Float($0) }
                ),
                enableLabel: "LFO",
                mixLabel: "LFO Amount"
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: effectsPanelCornerRadius, style: .continuous)
                .fill(expandedPanelFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: effectsPanelCornerRadius, style: .continuous)
                .stroke(expandedPanelStroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Effect Rack")
    }

    private var activeEffectsCount: Int {
        var count = 0
        if session.effectSettings.reverbEnabled { count += 1 }
        if session.effectSettings.delayEnabled { count += 1 }
        if session.effectSettings.lfoEnabled { count += 1 }
        return count
    }

    private func effectsHeader(activeCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Effects")
                    .font(.custom("ZTTalk-Bold", size: 20, relativeTo: .title3))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(activeEffectsDescription(activeCount: activeCount))
                    .font(.custom("ZTTalk-Regular", size: 12, relativeTo: .caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func activeEffectsDescription(activeCount: Int) -> String {
        switch activeCount {
        case 0: return "No effects active"
        case 1: return "1 active"
        case 2: return "2 active"
        case 3: return "3 active"
        default: return "No effects active"
        }
    }

    private var effectDivider: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(colorScheme == .dark ? Color.primary.opacity(0.08) : Color.black.opacity(0.07))
                .frame(height: 1)
                .padding(.leading, 50)
        }
        .padding(.vertical, 0)
    }

    @ViewBuilder
    private func effectRow(
        systemImage: String,
        title: String,
        description: String,
        isEnabled: Binding<Bool>,
        mixValue: Binding<Double>,
        enableLabel: String,
        mixLabel: String
    ) -> some View {
        let percentage = Int((mixValue.wrappedValue * 100).rounded())
        let enabled = isEnabled.wrappedValue

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                effectIcon(systemImage: systemImage, enabled: enabled)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(description)
                        .font(.custom("ZTTalk-Regular", size: 12, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(percentage)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                enableSwitch(
                    isEnabled: isEnabled,
                    enableLabel: enableLabel
                )
            }

            Slider(
                value: mixValue,
                in: 0...1
            )
            .controlSize(.small)
            .tint(.primary)
            .opacity(enabled ? 1 : 0.55)
            .accessibilityLabel(mixLabel)
            .accessibilityValue("\(percentage) percent")
        }
        .padding(.vertical, 12)
    }

    private func effectIcon(systemImage: String, enabled: Bool) -> some View {
        let backgroundFill: Color = if colorScheme == .dark {
            enabled ? Color.primary.opacity(0.10) : Color.secondary.opacity(0.10)
        } else {
            Color.black.opacity(enabled ? 0.09 : 0.07)
        }

        return Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 38, height: 38)
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(backgroundFill)
            }
            .accessibilityHidden(true)
    }

    private func enableSwitch(
        isEnabled: Binding<Bool>,
        enableLabel: String
    ) -> some View {
        let enabled = isEnabled.wrappedValue
        return Toggle("", isOn: isEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel(enabled ? "Disable \(enableLabel)" : "Enable \(enableLabel)")
            .accessibilityValue(enabled ? "On" : "Off")
    }

    private func handlePanelToggle(_ target: JamControlPanel) {
        if selectedPanel == target && isPanelPresented {
            closePanel()
        } else if selectedPanel != .none && isPanelPresented {
            withAnimation(.easeOut(duration: 0.12)) {
                selectedPanel = target
            }
        } else {
            selectedPanel = target
            withAnimation(panelRevealAnimation) {
                isPanelPresented = true
            }
        }
    }

    private func closePanel() {
        withAnimation(panelRevealAnimation) {
            isPanelPresented = false
        } completion: {
            if !isPanelPresented {
                selectedPanel = .none
            }
        }
    }

    private var panelRevealAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.26, dampingFraction: 0.96)
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
        JamSelectedPhotoArea(
            session: session,
            visualTransport: visualTransport,
            sounds: library.items,
            coverDataByID: library.coverDataByID,
            reduceMotion: reduceMotion,
            selectedJamRole: selectedJamRole,
            changePhotosButton: { changePhotosButton() },
            onTapRole: handleRoleTap,
            onDropPhotoID: handleTileDrop,
            onSwapForAccessibility: performSwapFromAccessibility
        )
    }

    private var sequencerAndStatus: some View {
        JamSequencerAndStatus(
            steps: jamStepsPerBar,
            session: session,
            playbackController: playbackController,
            visualTransport: visualTransport,
            activeStepsBySoundID: session.activeArrangement?.activeStepsBySoundID ?? [:],
            roleByID: session.slotAssignments.assignedRolesByID,
            roleColors: rowColorMap,
            bpm: Int(jamBPM),
            reduceMotion: reduceMotion
        )
        .frame(height: 150)
        .frame(maxWidth: .infinity)
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
            selectedMelodyIntent = .subtle
        }
        if selectedPanel == .arrange && !canOpenArrangePanel {
            closePanel()
        }
    }

    private var isMelodyPlayable: Bool {
        guard let melodyID = session.slotAssignments.melody,
              let sound = library.items.first(where: { $0.id == melodyID }) else {
            return false
        }
        return !sound.sequence.notes.isEmpty
    }

    private var displayedReferenceArrangement: JamArrangement? {
        playbackController.pendingArrangement ?? session.activeArrangement
    }

    private var canOpenArrangePanel: Bool {
        guard let selectedJamRole else { return false }
        return isRolePlayable(selectedJamRole)
    }

    private var isMelodyArrangeAvailable: Bool {
        selectedJamRole == .melody && isMelodyPlayable
    }

    private func isRolePlayable(_ role: JamRole) -> Bool {
        guard let roleID = session.slotAssignments.photoID(for: role),
              let sound = library.items.first(where: { $0.id == roleID }) else {
            return false
        }
        return !sound.sequence.notes.isEmpty
    }

    private func applyNextMelodyPhrase(intent: MelodyPhraseIntent) {
        guard isMelodyPlayable,
              let result = findNextMelodyVariation(
                after: session.melodyVariation,
                intent: intent,
                referenceArrangement: displayedReferenceArrangement,
                buildArrangement: { assignments, variation, mode in
                    buildArrangement(for: assignments, melodyVariation: variation, buildMode: mode)
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
            melodyVariation: session.melodyVariation,
            buildMode: .standard
        )
    }

    private func buildArrangement(
        for assignments: JamSlotAssignments,
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
        buildArrangement: (JamSlotAssignments, JamMelodyVariation, MelodyVariationBuildMode) -> JamArrangement?
    ) -> MelodyVariationSearchResult? {
        let referenceSequence = referenceArrangement?.sequence
        let prioritizedAttempts = prioritizedVariationAttempts(after: currentVariation, intent: intent)
        var bestAccepted: (result: MelodyVariationSearchResult, fitness: Double)?
        var bestAcceptedBelowThreshold: (result: MelodyVariationSearchResult, fitness: Double)?
        var bestOverall: (result: MelodyVariationSearchResult, fitness: Double)?

        for attempt in prioritizedAttempts {
            let variation = JamMelodyVariation(generation: currentVariation.generation &+ UInt64(attempt))
            let family = MelodyVariationFamily(generation: variation.generation)
            guard let arrangement = buildArrangement(session.slotAssignments, variation, .standard) else { continue }

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
              let fallbackArrangement = buildArrangement(session.slotAssignments, bestOverall.result.variation, .fallback) else {
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

private struct JamSelectedPhotoTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let sound: PhotoSound?
    let coverData: Data?
    let role: JamRole?
    let isActive: Bool
    let isSelected: Bool
    let reduceMotion: Bool
    let photoColor: Color?
    let onTap: () -> Void
    let onDropPhotoID: (String) -> Void
    let onSwapForAccessibility: (JamRole, JamRole) -> Void

    @State private var targetedDropRole: JamRole?
    @State private var playbackEnterTrigger = 0

    var body: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                travelingPhotoContent
            }
            .overlay(alignment: .topLeading) {
                if let role {
                    Text(role.displayName)
                        .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.64), in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !noteLabel.isEmpty {
                    Text(noteLabel)
                        .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.64), in: Capsule())
                        .padding(6)
                }
            }
            .overlay {
                if isHoverTarget {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(dropTargetFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(dropTargetBorder, lineWidth: dropTargetBorderWidth)
                        }
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .opacity(role == nil ? 0.58 : 1)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .animation(dropTargetAnimation, value: isHoverTarget)
            .onTapGesture(perform: onTap)
            .modifier(JamTileDragAndDrop(
                role: role,
                photoID: sound?.id,
                targetedRole: $targetedDropRole,
                onDropPhotoID: onDropPhotoID
            ))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .modifier(JamTileAccessibilityActions(
                role: role,
                performSwap: { target in performSwapForAccessibility(target: target) }
            ))
            .onChange(of: isActive) { oldValue, newValue in
                guard !oldValue, newValue else { return }
                playbackEnterTrigger &+= 1
            }
    }

    private var isHoverTarget: Bool {
        targetedDropRole != nil
    }

    private var travelingPhotoContent: some View {
        let style = visualStyle

        return playbackAnimatedContent(style: style)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .shadow(
                color: style.shadowColor,
                radius: style.shadowRadius,
                y: style.shadowYOffset
            )
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
                        .allowsHitTesting(false)
                }
            }
            .animation(activeStateAnimation, value: activeVisualStateKey)
    }

    private func playbackAnimatedContent(style: JamTileVisualStyle) -> some View {
        coverImage
            .phaseAnimator([PlaybackImpulsePhase.rest, .lifted, .settled], trigger: playbackEnterTrigger) { content, phase in
                content
                    .scaleEffect(style.playbackImpulseScale(for: phase))
                    .offset(y: style.playbackImpulseYOffset(for: phase))
                    .shadow(
                        color: style.playbackImpulseShadowColor(for: phase),
                        radius: style.playbackImpulseShadowRadius(for: phase),
                        y: style.playbackImpulseShadowYOffset(for: phase)
                    )
            } animation: { phase in
                switch phase {
                case .rest:
                    .linear(duration: 0)
                case .lifted:
                    reduceMotion
                        ? .easeOut(duration: 0.14)
                        : .spring(response: 0.24, dampingFraction: 0.86)
                case .settled:
                    reduceMotion
                        ? .easeOut(duration: 0.12)
                        : .spring(response: 0.20, dampingFraction: 1.0)
                }
            }
    }

    private var visualStyle: JamTileVisualStyle {
        JamTileVisualStyle(
            colorScheme: colorScheme,
            reduceMotion: reduceMotion,
            accentColor: photoColor,
            hasRole: role != nil,
            isSelected: isSelected,
            isActive: isActive
        )
    }

    private var activeVisualStateKey: Int {
        var key = 0
        if isSelected { key += 1 }
        if isActive { key += 2 }
        return key
    }

    private var activeStateAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.14)
        }
        return isActive
            ? .spring(response: 0.24, dampingFraction: 0.86)
            : .spring(response: 0.20, dampingFraction: 1.0)
    }

    private var dropTargetFill: Color {
        switch colorScheme {
        case .dark:
            return (photoColor ?? .white).opacity(0.10)
        default:
            return (photoColor ?? .black).opacity(0.08)
        }
    }

    private var dropTargetBorder: Color {
        switch colorScheme {
        case .dark:
            return (photoColor ?? .white).opacity(0.52)
        default:
            return (photoColor ?? .black).opacity(0.44)
        }
    }

    private var dropTargetBorderWidth: CGFloat {
        reduceMotion ? 1.5 : 2
    }

    private var dropTargetAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.20, dampingFraction: 0.96)
    }

    private func performSwapForAccessibility(target: JamRole) {
        guard let source = role, source != target else { return }
        onSwapForAccessibility(source, target)
    }

    private var accessibilityName: String {
        guard let sound else {
            if let role { return role.displayName }
            return "Empty slot"
        }
        let note = sound.sequence.harmony.rootName
        if let role {
            return "\(role.displayName), \(note)"
        }
        return sound.name ?? sound.sequence.displayLabel
    }

    @ViewBuilder
    private var coverImage: some View {
        GeometryReader { geometry in
            if let coverData, let image = UIImage(data: coverData) {
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

    private var noteLabel: String {
        sound?.sequence.harmony.rootName ?? ""
    }

    private var accessibilityValue: String {
        if let role {
            if isSelected {
                return "Selected"
            }
            return isActive ? "\(role.displayName), active on this step" : role.displayName
        }

        return sound == nil ? "Empty slot" : "No musical material"
    }

    private var accessibilityHint: String {
        guard let role, sound != nil else { return "" }
        return role == .melody
            ? "Selects this role for arrange controls"
            : "Selects this role"
    }
}

private enum MelodyPhraseIntent: String, CaseIterable, Identifiable {
    case subtle
    case energetic
    case sparse
    case surprise

    var id: Self { self }

    var title: String {
        switch self {
        case .subtle: "SUBTLE"
        case .energetic: "ENERGETIC"
        case .sparse: "SPARSE"
        case .surprise: "SURPRISE"
        }
    }

    var subtitle: String {
        switch self {
        case .subtle: "Keeps the groove"
        case .energetic: "More movement"
        case .sparse: "More space"
        case .surprise: "Bigger change"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .subtle: "Subtle melody"
        case .energetic: "Energetic melody"
        case .sparse: "Sparse melody"
        case .surprise: "Surprise melody"
        }
    }

    var preferredFamilies: [MelodyVariationFamily] {
        switch self {
        case .subtle: [.contour, .register, .rhythm, .full]
        case .energetic: [.rhythm, .full, .contour, .register]
        case .sparse: [.rhythm, .contour, .register, .full]
        case .surprise: [.full, .rhythm, .contour, .register]
        }
    }
}

private struct JamArrangePanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let role: JamRole?
    let selectedIntent: MelodyPhraseIntent
    let isMelodyActionEnabled: Bool
    let fill: Color
    let stroke: Color
    let onSelectIntent: (MelodyPhraseIntent) -> Void
    let onApply: () -> Void

    private let cornerRadius: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            switch role {
            case .melody:
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(MelodyPhraseIntent.allCases) { intent in
                        intentButton(intent)
                    }
                }
                .padding(.horizontal, 18)

                Button(action: onApply) {
                    Text("NEW PHRASE")
                        .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(isMelodyActionEnabled ? 0.92 : 0.42))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(isMelodyActionEnabled ? 0.10 : 0.05), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!isMelodyActionEnabled)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 18)
                .accessibilityLabel("New phrase")
                .accessibilityHint("Generates the next melody phrase using the selected intent")

            case .bass:
                placeholderBody("Bass variations coming next.")

            case .harmony:
                placeholderBody("Harmony variations coming next.")

            case .none:
                placeholderBody("Select a playable photo to arrange.")
            }
        }
        .frame(width: 320, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(stroke, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Arrange controls")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(roleTitle)
                .font(.custom("ZTTalk-Bold", size: 20, relativeTo: .title3))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(roleSubtitle)
                .font(.custom("ZTTalk-Regular", size: 12, relativeTo: .caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func placeholderBody(_ message: String) -> some View {
        Text(message)
            .font(.custom("ZTTalk-Regular", size: 14, relativeTo: .body))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .accessibilityLabel(message)
    }

    private var roleTitle: String {
        switch role {
        case .bass: "BASS"
        case .harmony: "HARMONY"
        case .melody: "MELODY"
        case .none: "ARRANGE"
        }
    }

    private var roleSubtitle: String {
        switch role {
        case .bass: "Shape the bass pattern"
        case .harmony: "Shape the harmony"
        case .melody: "Shape the next phrase"
        case .none: "Select a playable photo"
        }
    }

    private func intentButton(_ intent: MelodyPhraseIntent) -> some View {
        let isSelected = selectedIntent == intent
        let selectedFill = colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.07)
        let selectedStroke = colorScheme == .dark
            ? Color.white.opacity(0.22)
            : Color.black.opacity(0.14)

        return Button {
            onSelectIntent(intent)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(intent.title)
                    .font(.custom("ZTTalk-Bold", size: 13, relativeTo: .footnote))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(intent.subtitle)
                    .font(.custom("ZTTalk-Regular", size: 11, relativeTo: .caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? selectedFill : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? selectedStroke : stroke, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(intent.accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct JamVibePanelContent: View {
    let session: JamSessionState
    let expandedPanelFill: Color
    let expandedPanelStroke: Color
    let onPositionChanged: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(expandedPanelFill)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(expandedPanelStroke, lineWidth: 1)
            VibeControl(
                position: Binding(
                    get: { session.vibePosition },
                    set: { session.vibePosition = $0 }
                ),
                onPositionChanged: onPositionChanged
            )
        }
        .frame(width: 254, height: 254)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("Vibe control")
        .accessibilityValue(thumbnailLabel)
    }

    private var thumbnailLabel: String {
        switch JamGrooveLibrary.region(for: session.vibePosition) {
        case .airy: "Airy"
        case .bright: "Bright"
        case .deep: "Deep"
        case .intense: "Intense"
        }
    }
}

private struct JamSelectedPhotoArea<ChangePhotosButton: View>: View {
    let session: JamSessionState
    let visualTransport: JamVisualTransportState
    let sounds: [PhotoSound]
    let coverDataByID: [UUID: Data]
    let reduceMotion: Bool
    let selectedJamRole: JamRole?
    let changePhotosButton: () -> ChangePhotosButton
    let onTapRole: (JamRole?) -> Void
    let onDropPhotoID: (String, JamRole?) -> Void
    let onSwapForAccessibility: (JamRole, JamRole, UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ForEach(JamRole.allCases, id: \.self) { role in
                    roleSlot(for: role)
                }
            }
            .frame(maxWidth: .infinity)

            changePhotosButton()
        }
    }

    @ViewBuilder
    private func roleSlot(for role: JamRole) -> some View {
        let photoID = session.slotAssignments.photoID(for: role)
        let sound = photoID.flatMap { id in sounds.first(where: { $0.id == id }) }
        let isActive = photoID.map { visualTransport.activeSoundIDs.contains($0) } ?? false
        let color = photoColor(for: role)

        JamSelectedPhotoTile(
            sound: sound,
            coverData: sound.flatMap { coverDataByID[$0.id] },
            role: photoID == nil ? nil : role,
            isActive: photoID != nil && isActive,
            isSelected: selectedJamRole == role,
            reduceMotion: reduceMotion,
            photoColor: color,
            onTap: {
                onTapRole(photoID == nil ? nil : role)
            },
            onDropPhotoID: { droppedID in
                onDropPhotoID(droppedID, role)
            },
            onSwapForAccessibility: { _, target in
                guard let photoID else { return }
                onSwapForAccessibility(role, target, photoID)
            }
        )
        .id(role)
    }

    private func photoColor(for role: JamRole) -> Color? {
        guard let roleID = session.slotAssignments.photoID(for: role),
              let sound = sounds.first(where: { $0.id == roleID })
        else { return nil }
        let pitch = PitchClass(rawValue: sound.sequence.harmony.rootPitchClass) ?? .c
        return Color(RetroCoverRenderer.tonalPalette(for: pitch).base)
    }
}

private struct JamTileDragAndDrop: ViewModifier {
    let role: JamRole?
    let photoID: UUID?
    @Binding var targetedRole: JamRole?
    let onDropPhotoID: (String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let role, let photoID {
            content
                .draggable(photoID.uuidString) {
                    Text(role.displayName)
                        .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                        .opacity(0.90)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let first = items.first else { return false }
                    onDropPhotoID(first)
                    // Clear hover immediately so the destination tile is not
                    // still highlighted when the swap mutates the source view.
                    if targetedRole == role {
                        targetedRole = nil
                    }
                    return true
                } isTargeted: { isOver in
                    if isOver {
                        if targetedRole != role { targetedRole = role }
                    } else if targetedRole == role {
                        targetedRole = nil
                    }
                }
        } else {
            content
        }
    }
}

private enum PlaybackImpulsePhase: CaseIterable {
    case rest
    case lifted
    case settled
}

private struct JamTileVisualStyle {
    let borderColor: Color
    let borderWidth: CGFloat
    let selectionFill: Color
    let contrastFill: Color
    let shadowColor: Color
    let shadowRadius: CGFloat
    let shadowYOffset: CGFloat
    let haloColor: Color
    let haloOpacity: Double
    let haloLineWidth: CGFloat
    let haloBlurRadius: CGFloat
    let baseScale: CGFloat
    let baseYOffset: CGFloat
    let playingImpulseScaleDelta: CGFloat
    let playingImpulseYOffset: CGFloat
    let playingImpulseShadowColor: Color
    let playingImpulseShadowRadius: CGFloat
    let playingImpulseShadowYOffset: CGFloat

    init(
        colorScheme: ColorScheme,
        reduceMotion: Bool,
        accentColor: Color?,
        hasRole: Bool,
        isSelected: Bool,
        isActive: Bool
    ) {
        let accent = accentColor ?? .primary
        let idleBorder: Color = switch colorScheme {
        case .dark:
            .white.opacity(hasRole ? 0.12 : 0.08)
        default:
            .black.opacity(hasRole ? 0.12 : 0.09)
        }

        let selectedBorder: Color = switch colorScheme {
        case .dark:
            accent.opacity(0.78)
        default:
            accent.opacity(0.62)
        }

        let playingBorder: Color = switch colorScheme {
        case .dark:
            .white.opacity(0.72)
        default:
            .black.opacity(0.42)
        }

        let selectedPlayingBorder: Color = switch colorScheme {
        case .dark:
            accent.opacity(0.86)
        default:
            .black.opacity(0.50)
        }

        if isSelected && isActive {
            borderColor = selectedPlayingBorder
            borderWidth = 2
            baseScale = reduceMotion ? 1 : 1.016
            baseYOffset = reduceMotion ? 0 : -1.2
        } else if isActive {
            borderColor = playingBorder
            borderWidth = 1.5
            baseScale = reduceMotion ? 1 : 1.014
            baseYOffset = reduceMotion ? 0 : -1.0
        } else if isSelected {
            borderColor = selectedBorder
            borderWidth = 2
            baseScale = reduceMotion ? 1 : 1.009
            baseYOffset = 0
        } else {
            borderColor = idleBorder
            borderWidth = 1
            baseScale = 1
            baseYOffset = 0
        }

        selectionFill = isSelected ? accent.opacity(colorScheme == .dark ? 0.11 : 0.08) : .clear
        contrastFill = switch (colorScheme, isActive) {
        case (.dark, true):
            .white.opacity(0.035)
        case (.light, true):
            .black.opacity(0.045)
        default:
            .clear
        }

        shadowColor = switch colorScheme {
        case .dark:
            isActive ? accent.opacity(isSelected ? 0.22 : 0.18) : accent.opacity(isSelected ? 0.16 : 0)
        default:
            isActive ? .black.opacity(isSelected ? 0.18 : 0.14) : .black.opacity(isSelected ? 0.10 : 0)
        }
        shadowRadius = reduceMotion ? 0 : (isActive ? 8 : (isSelected ? 6 : 0))
        shadowYOffset = reduceMotion ? 0 : (isActive ? 4 : (isSelected ? 3 : 0))

        haloColor = accent
        haloOpacity = colorScheme == .dark && isActive ? (isSelected ? 0.26 : 0.18) : 0
        haloLineWidth = 1.25
        haloBlurRadius = reduceMotion ? 0 : 4

        playingImpulseScaleDelta = reduceMotion ? 0 : 0.008
        playingImpulseYOffset = reduceMotion ? 0 : -1.4
        playingImpulseShadowColor = switch colorScheme {
        case .dark:
            accent.opacity(0.22)
        default:
            .black.opacity(0.12)
        }
        playingImpulseShadowRadius = reduceMotion ? 0 : 8
        playingImpulseShadowYOffset = reduceMotion ? 0 : 4
    }

    func playbackImpulseScale(for phase: PlaybackImpulsePhase) -> CGFloat {
        switch phase {
        case .rest:
            1
        case .lifted:
            1 + playingImpulseScaleDelta
        case .settled:
            1
        }
    }

    func playbackImpulseYOffset(for phase: PlaybackImpulsePhase) -> CGFloat {
        switch phase {
        case .rest:
            0
        case .lifted:
            playingImpulseYOffset
        case .settled:
            0
        }
    }

    func playbackImpulseShadowColor(for phase: PlaybackImpulsePhase) -> Color {
        switch phase {
        case .lifted:
            playingImpulseShadowColor
        case .rest, .settled:
            .clear
        }
    }

    func playbackImpulseShadowRadius(for phase: PlaybackImpulsePhase) -> CGFloat {
        phase == .lifted ? playingImpulseShadowRadius : 0
    }

    func playbackImpulseShadowYOffset(for phase: PlaybackImpulsePhase) -> CGFloat {
        phase == .lifted ? playingImpulseShadowYOffset : 0
    }
}

private struct JamTileAccessibilityActions: ViewModifier {
    let role: JamRole?
    let performSwap: (JamRole) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let role {
            let allRoles: [JamRole] = [.bass, .harmony, .melody]
            let otherRoles = allRoles.filter { $0 != role }
            let labels = otherRoles.map { "Move to \($0.displayName)" }
            content
                .accessibilityAction(named: labels[0]) {
                    performSwap(otherRoles[0])
                }
                .accessibilityAction(named: labels[1]) {
                    performSwap(otherRoles[1])
                }
        } else {
            content
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

private enum JamControlPanel: Equatable {
    case none
    case kits
    case vibe
    case arrange
    case effects
}

private enum JamPersistenceError: Equatable {
    case notFound
    case corruptedFile(UUID)
    case unsupportedSchemaVersion(Int)
    case writeFailed
}

private struct JamSequencerAndStatus: View {
    @Environment(\.colorScheme) private var colorScheme

    let steps: Int
    let session: JamSessionState
    let playbackController: JamPlaybackController
    let visualTransport: JamVisualTransportState
    let activeStepsBySoundID: [UUID: Set<Int>]
    let roleByID: [UUID: JamRole]
    let roleColors: [JamRole: Color]
    let bpm: Int
    let reduceMotion: Bool

    private var structuralCardFill: Color {
        switch colorScheme {
        case .dark:
            Color.secondary.opacity(0.06)
        default:
            Color.black.opacity(0.05)
        }
    }

    private var structuralCardStroke: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.08)
        default:
            Color.black.opacity(0.10)
        }
    }

    private var structuralDivider: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.08)
        default:
            Color.black.opacity(0.07)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sequencerContent
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Rectangle()
                .fill(structuralDivider)
                .frame(height: 1)
                .padding(.horizontal, 14)

            statusContent
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(structuralCardFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(structuralCardStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(statusPrimaryText), \(statusSecondaryText), \(bpm) BPM")
    }

    private var sequencerContent: some View {
        JamSequencerRows(
            steps: steps,
            visualTransport: visualTransport,
            activeStepsBySoundID: activeStepsBySoundID,
            roleByID: roleByID,
            roleColors: roleColors,
            reduceMotion: reduceMotion
        )
    }

    private var statusContent: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(statusPrimaryText)
                    .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(statusSecondaryText)
                    .font(.custom("ZTTalk-Medium", size: 12, relativeTo: .caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(bpm) BPM")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var statusPrimaryText: String {
        if session.slotAssignments.allPhotoIDs.isEmpty { return "READY" }
        if applyingNextBar { return "NEXT BAR" }
        return session.isPlaying ? "PLAYING" : "READY"
    }

    private var statusSecondaryText: String {
        if session.slotAssignments.allPhotoIDs.isEmpty { return "ADD PHOTOS TO START" }
        if applyingNextBar { return "ARRANGEMENT CHANGE" }
        if session.isPlaying {
            let region = JamGrooveLibrary.region(for: session.vibePosition)
            let drumKit = resolvedDrumKit(selection: session.drumKitSelection, region: region)
            return "\(regionDisplayName(region)) · \(drumKitDisplayName(drumKit))"
        }
        let activeSlotCount = session.slotAssignments.activePhotoIDs.count
        let reserveCount = session.slotAssignments.reserve.count
        return "\(activeSlotCount) ACTIVE · \(reserveCount) IN BANK"
    }

    private var applyingNextBar: Bool {
        session.isPlaying && playbackController.hasPendingArrangementChanges
    }

    private func regionDisplayName(_ region: JamRegion) -> String {
        switch region {
        case .airy: "Airy"
        case .bright: "Bright"
        case .deep: "Deep"
        case .intense: "Intense"
        }
    }

    private func drumKitDisplayName(_ kit: MusicDrumKit) -> String {
        switch kit {
        case .soft: "Soft"
        case .club: "Club"
        case .breakbeat: "Break"
        case .metal: "Metal"
        }
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

private struct JamSequencerRows: View {
    let steps: Int
    let visualTransport: JamVisualTransportState
    let activeStepsBySoundID: [UUID: Set<Int>]
    let roleByID: [UUID: JamRole]
    let roleColors: [JamRole: Color]
    let reduceMotion: Bool

    private static let rowOrder: [JamRole] = [.bass, .harmony, .melody]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.rowOrder.enumerated()), id: \.element) { _, role in
                sequencerRow(role: role)
            }
        }
    }

    private func sequencerRow(role: JamRole) -> some View {
        let activeSteps = activeStepsForRole(role)
        return HStack(spacing: 8) {
            Text(role.displayName.uppercased())
                .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            HStack(spacing: 3) {
                ForEach(0..<steps, id: \.self) { step in
                    stepCell(role: role, step: step, isActiveInRow: activeSteps.contains(step))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func stepCell(role: JamRole, step: Int, isActiveInRow: Bool) -> some View {
        let isPlayhead = step == visualTransport.currentStep
        let rowColor = roleColors[role]
        let inactiveColor = Color.secondary.opacity(0.16)
        let activeColor = (rowColor ?? .secondary).opacity(0.55)
        let playheadColor = rowColor ?? .primary

        let baseFill: Color = isActiveInRow
            ? (isPlayhead ? playheadColor : activeColor)
            : (rowColor != nil ? rowColor!.opacity(0.16) : inactiveColor)

        let playheadStroke = isPlayhead && !isActiveInRow
            ? (rowColor ?? .primary).opacity(0.55)
            : nil

        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(baseFill)
            .frame(maxWidth: .infinity)
            .frame(height: 11)
            .overlay {
                if let playheadStroke {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(playheadStroke, lineWidth: 1)
                }
            }
            .scaleEffect(isActiveInRow && isPlayhead && !reduceMotion ? 1.07 : 1)
            .shadow(
                color: isActiveInRow && isPlayhead
                    ? (rowColor ?? .primary).opacity(0.45)
                    : .clear,
                radius: isActiveInRow && isPlayhead ? 3 : 0
            )
            .accessibilityHidden(true)
    }

    private func activeStepsForRole(_ role: JamRole) -> Set<Int> {
        var result: Set<Int> = []
        for (soundID, steps) in activeStepsBySoundID where roleByID[soundID] == role {
            result.formUnion(steps)
        }
        return result
    }
}

private struct JamDockBar: View {
    @Binding var selectedPanel: JamControlPanel
    @Binding var isPanelPresented: Bool
    let session: JamSessionState
    let selectedJamRole: JamRole?
    let canOpenArrangePanel: Bool
    let onPanelToggle: (JamControlPanel) -> Void

    private static let tileSize: CGFloat = 62
    private static let tileSpacing: CGFloat = 8
    private static let cornerRadius: CGFloat = 18
    private static let iconSlotSize: CGFloat = 20

    var body: some View {
        HStack(spacing: Self.tileSpacing) {
            kitsTileButton
            vibeTileButton
            arrangeTileButton
            effectsTileButton
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var kitsTileButton: some View {
        Button {
            onPanelToggle(.kits)
        } label: {
            KitsDockTile(
                cornerRadius: Self.cornerRadius,
                iconSlotSize: Self.iconSlotSize,
                isActive: selectedPanel == .kits && isPanelPresented
            )
        }
        .buttonStyle(.plain)
        .frame(width: Self.tileSize, height: Self.tileSize)
        .accessibilityLabel("Kits")
        .accessibilityValue("\(selectedPanel == .kits && isPanelPresented ? "Expanded" : "Collapsed")")
    }

    private var vibeTileButton: some View {
        Button {
            onPanelToggle(.vibe)
        } label: {
            VibeDockTile(
                position: session.vibePosition,
                cornerRadius: Self.cornerRadius,
                iconSlotSize: Self.iconSlotSize,
                isActive: selectedPanel == .vibe && isPanelPresented
            )
        }
        .buttonStyle(.plain)
        .frame(width: Self.tileSize, height: Self.tileSize)
        .accessibilityLabel("Vibe")
        .accessibilityValue(thumbnailLabel)
    }

    private var arrangeTileButton: some View {
        Button {
            onPanelToggle(.arrange)
        } label: {
            ArrangeDockTile(
                cornerRadius: Self.cornerRadius,
                iconSlotSize: Self.iconSlotSize,
                isActive: selectedPanel == .arrange && isPanelPresented,
                isEnabled: canOpenArrangePanel
            )
        }
        .buttonStyle(.plain)
        .disabled(!canOpenArrangePanel)
        .frame(width: Self.tileSize, height: Self.tileSize)
        .accessibilityLabel("Arrange")
        .accessibilityValue(arrangeAccessibilityValue)
        .accessibilityHint(arrangeAccessibilityHint)
    }

    private var effectsTileButton: some View {
        Button {
            onPanelToggle(.effects)
        } label: {
            EffectsDockTile(
                cornerRadius: Self.cornerRadius,
                iconSlotSize: Self.iconSlotSize,
                isActive: selectedPanel == .effects && isPanelPresented
            )
        }
        .buttonStyle(.plain)
        .frame(width: Self.tileSize, height: Self.tileSize)
        .accessibilityLabel("Effects")
        .accessibilityValue("Empty")
    }

    private var thumbnailLabel: String {
        switch JamGrooveLibrary.region(for: session.vibePosition) {
        case .airy: "Airy"
        case .bright: "Bright"
        case .deep: "Deep"
        case .intense: "Intense"
        }
    }

    private var arrangeAccessibilityValue: String {
        if selectedPanel == .arrange && isPanelPresented {
            return "Expanded"
        }
        if canOpenArrangePanel {
            return "Available"
        }
        return "Unavailable"
    }

    private var arrangeAccessibilityHint: String {
        guard !canOpenArrangePanel else { return "Opens arrange controls for the selected photo." }
        switch selectedJamRole {
        case .bass:
            return "Select a playable Bass photo to use Arrange."
        case .harmony:
            return "Select a playable Harmony photo to use Arrange."
        case .melody:
            return "Select a playable Melody photo to use Arrange."
        case .none:
            return "Select a playable photo to use Arrange."
        }
    }
}

private struct KitsDockTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let iconSlotSize: CGFloat
    var isActive: Bool = false

    private var tileFill: Color {
        switch colorScheme {
        case .dark:
            Color.secondary.opacity(isActive ? 0.16 : 0.10)
        default:
            Color.black.opacity(isActive ? 0.09 : 0.075)
        }
    }

    private var tileStroke: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(isActive ? 0.22 : 0.10)
        default:
            Color.black.opacity(isActive ? 0.12 : 0.10)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tileFill)

            VStack(spacing: 3) {
                dockIconSlot {
                    Image("drum-svg")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundStyle(.primary)
                }

                Text("Kits")
                    .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(tileStroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func dockIconSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()
        }
        .frame(width: iconSlotSize, height: iconSlotSize)
    }
}

private struct VibeDockTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let position: CGPoint
    let cornerRadius: CGFloat
    let iconSlotSize: CGFloat
    var isActive: Bool = false

    private var tileFill: Color {
        switch colorScheme {
        case .dark:
            Color.secondary.opacity(isActive ? 0.16 : 0.10)
        default:
            Color.black.opacity(isActive ? 0.09 : 0.075)
        }
    }

    private var tileStroke: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(isActive ? 0.22 : 0.10)
        default:
            Color.black.opacity(isActive ? 0.12 : 0.10)
        }
    }

    private var axisStroke: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.22)
        default:
            Color.black.opacity(0.11)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tileFill)

            VStack(spacing: 3) {
                dockIconSlot {
                    ZStack {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 11))
                            path.addLine(to: CGPoint(x: 22, y: 11))
                            path.move(to: CGPoint(x: 11, y: 0))
                            path.addLine(to: CGPoint(x: 11, y: 22))
                        }
                        .stroke(axisStroke, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                        Circle()
                            .fill(Color.primary)
                            .frame(width: 4, height: 4)
                            .position(
                                x: min(max(position.x, 0), 1) * 22,
                                y: min(max(position.y, 0), 1) * 22
                            )
                    }
                    .frame(width: 22, height: 22)
                }

                Text("Vibe")
                    .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(tileStroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func dockIconSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()
        }
        .frame(width: iconSlotSize, height: iconSlotSize)
    }
}

private struct ArrangeDockTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let iconSlotSize: CGFloat
    var isActive: Bool = false
    var isEnabled: Bool = true

    private var tileFill: Color {
        switch colorScheme {
        case .dark:
            Color.secondary.opacity(isActive ? 0.16 : 0.10)
        default:
            Color.black.opacity(isActive ? 0.09 : 0.075)
        }
    }

    private var tileStroke: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(isActive ? 0.22 : 0.10)
        default:
            Color.black.opacity(isActive ? 0.12 : 0.10)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tileFill)

            VStack(spacing: 3) {
                dockIconSlot {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Text("Arrange")
                    .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .opacity(isEnabled ? 1 : 0.48)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(tileStroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func dockIconSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()
        }
        .frame(width: iconSlotSize, height: iconSlotSize)
    }
}

private struct EffectsDockTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat
    let iconSlotSize: CGFloat
    var isActive: Bool = false

    private var tileFill: Color {
        switch colorScheme {
        case .dark:
            Color.secondary.opacity(isActive ? 0.16 : 0.10)
        default:
            Color.black.opacity(isActive ? 0.09 : 0.075)
        }
    }

    private var tileStroke: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(isActive ? 0.22 : 0.10)
        default:
            Color.black.opacity(isActive ? 0.12 : 0.10)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tileFill)

            VStack(spacing: 3) {
                dockIconSlot {
                    Image(systemName: "dial.medium")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                Text("Effects")
                    .font(.custom("ZTTalk-Bold", size: 11, relativeTo: .caption2))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(tileStroke, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func dockIconSlot<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()
        }
        .frame(width: iconSlotSize, height: iconSlotSize)
    }
}

private struct VibeControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @Binding var position: CGPoint
    let onPositionChanged: () -> Void

    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    @GestureState private var isDragging = false

    private var currentQuadrant: Quadrant {
        Quadrant(position: clampedPosition)
    }

    private var crosshairStroke: Color {
        switch colorScheme {
        case .dark:
            Color.white.opacity(0.10)
        default:
            Color.black.opacity(0.11)
        }
    }

    private var quadrantHighlightColors: [LinearGradient] {
        switch colorScheme {
        case .dark:
            [
                LinearGradient(colors: [Color.white.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .topTrailing, endPoint: .bottomLeading),
                LinearGradient(colors: [.clear, Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomLeading),
                LinearGradient(colors: [.clear, Color.white.opacity(0.03)], startPoint: .topTrailing, endPoint: .bottomTrailing)
            ]
        default:
            [
                LinearGradient(colors: [Color.black.opacity(0.035), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                LinearGradient(colors: [Color.black.opacity(0.025), .clear], startPoint: .topTrailing, endPoint: .bottomLeading),
                LinearGradient(colors: [.clear, Color.black.opacity(0.018)], startPoint: .topLeading, endPoint: .bottomLeading),
                LinearGradient(colors: [.clear, Color.black.opacity(0.014)], startPoint: .topTrailing, endPoint: .bottomTrailing)
            ]
        }
    }

    private var labelBackground: Color {
        switch colorScheme {
        case .dark:
            Color(uiColor: .systemBackground).opacity(0.62)
        default:
            Color.black.opacity(0.065)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let handlePosition = CGPoint(
                x: clampedPosition.x * size.width,
                y: clampedPosition.y * size.height
            )

            ZStack {
                quadrantHighlights

                crosshair

                cornerLabels

                Circle()
                    .fill(Color.primary)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.14), lineWidth: 10)
                            .blur(radius: 2)
                    }
                    .overlay {
                        Circle()
                            .stroke(Color(uiColor: .systemBackground), lineWidth: 3)
                    }
                    .scaleEffect(isDragging && !reduceMotion ? 1.03 : 1)
                    .shadow(color: .black.opacity(reduceMotion ? 0 : 0.14), radius: reduceMotion ? 0 : 8, y: reduceMotion ? 0 : 4)
                    .position(handlePosition)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        let newPosition = normalizedPosition(for: value.location, in: size)
                        position = newPosition
                        onPositionChanged()
                    }
                    .onEnded { value in
                        position = normalizedPosition(for: value.location, in: size)
                    }
            )
            .onAppear {
                feedbackGenerator.prepare()
            }
            .onChange(of: currentQuadrant) { oldValue, newValue in
                guard oldValue != newValue else { return }
                feedbackGenerator.impactOccurred()
                feedbackGenerator.prepare()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vibe control")
        .accessibilityHint("Drag to move between Airy, Bright, Deep, and Intense.")
    }

    private var clampedPosition: CGPoint {
        CGPoint(
            x: min(max(position.x, 0), 1),
            y: min(max(position.y, 0), 1)
        )
    }

    private var cornerWeights: CornerWeights {
        let x = clampedPosition.x
        let y = clampedPosition.y

        return CornerWeights(
            airy: (1 - x) * (1 - y),
            bright: x * (1 - y),
            deep: (1 - x) * y,
            intense: x * y
        )
    }

    private var crosshair: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: geometry.size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height))
                path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
            }
            .stroke(crosshairStroke, style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
    }

    private var quadrantHighlights: some View {
        ZStack {
            ForEach(Array(quadrantHighlightColors.enumerated()), id: \.offset) { _, gradient in
                Rectangle().fill(gradient)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var cornerLabels: some View {
        VStack {
            HStack {
                cornerLabel("Airy", weight: cornerWeights.airy)
                Spacer()
                cornerLabel("Bright", weight: cornerWeights.bright)
            }

            Spacer()

            HStack {
                cornerLabel("Deep", weight: cornerWeights.deep)
                Spacer()
                cornerLabel("Intense", weight: cornerWeights.intense)
            }
        }
        .padding(16)
    }

    private func cornerLabel(_ title: String, weight: CGFloat) -> some View {
        let prominence = 0.42 + weight * 0.58

        return Text(title)
            .font(.custom("ZTTalk-Bold", size: 13, relativeTo: .footnote))
            .foregroundStyle(Color.primary.opacity(prominence))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(labelBackground, in: Capsule())
            .scaleEffect(0.95 + weight * 0.07)
    }

    private func normalizedPosition(for location: CGPoint, in size: CGSize) -> CGPoint {
        let normalizedX = size.width > 0 ? location.x / size.width : 0.5
        let normalizedY = size.height > 0 ? location.y / size.height : 0.5

        return CGPoint(
            x: min(max(normalizedX, 0), 1),
            y: min(max(normalizedY, 0), 1)
        )
    }

}

private enum Quadrant: Equatable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    init(position: CGPoint) {
        switch (position.x >= 0.5, position.y >= 0.5) {
        case (false, false):
            self = .topLeft
        case (true, false):
            self = .topRight
        case (false, true):
            self = .bottomLeft
        case (true, true):
            self = .bottomRight
        }
    }
}

private enum PlaybackAction: Equatable {
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

private struct CornerWeights {
    let airy: CGFloat
    let bright: CGFloat
    let deep: CGFloat
    let intense: CGFloat
}

extension Color {
    fileprivate init(_ rgb: RGBColor) {
        self.init(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}
