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
    let initialCoverData: Data?
    let onClose: (() async -> Void)?

    private let arrangementBuilder = JamArrangementBuilder(bpm: Int(jamBPM))

    @State private var session = JamSessionState()
    @State private var visualTransport = JamVisualTransportState()
    @State private var selectedPanel: JamControlPanel = .none
    @State private var isPanelPresented = false
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
    private let effectsPanelWidth: CGFloat = 352
    private let effectsPanelHeight: CGFloat = 392
    private let effectsPanelCornerRadius: CGFloat = 22

    init(
        library: PhotoLibraryViewModel,
        isActive: Bool,
        initialJam: PersistedJam? = nil,
        initialCoverData: Data? = nil,
        onClose: (() async -> Void)? = nil
    ) {
        self.library = library
        self.isActive = isActive
        self.initialJam = initialJam
        self.initialCoverData = initialCoverData
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

            ScrollView {
                VStack(spacing: 18) {
                    sessionHeader

                    sessionBody
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomReserve)
                .frame(maxWidth: .infinity)
            }
            .blur(radius: isPanelPresented ? 2.5 : 0)
            .animation(.easeInOut(duration: 0.18), value: isPanelPresented)
            .scrollIndicators(.hidden)

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
        .onChange(of: session.slotAssignments) { _, assignments in
            if !session.isPlaying {
                session.activeArrangement = buildArrangement(for: assignments)
            }
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
        }
        .onDisappear {
            library.clearTransientLoopUpdatePreparedHandler()
            Task { await flushAutosave() }
            clearTransportAndPlayback()
        }
        .onChange(of: isActive) { _, isActive in
            guard !isActive else { return }
            Task { await flushAutosave() }
            clearTransportAndPlayback()
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
                session.activeArrangement = buildArrangement(for: cleanedAssignments)
            }

            session.slotAssignments = cleanedAssignments
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

    private var sessionHeader: some View {
        HStack(spacing: 12) {
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
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var sessionHeaderCover: some View {
        Color.clear
            .frame(width: 52, height: 52)
            .overlay {
                ZStack {
                    if let initialCoverImage {
                        Image(uiImage: initialCoverImage)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Rectangle()
                            .fill(.secondary.opacity(0.15))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
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
        session.isPlaying = false
        visualTransport.reset()
        playbackController.clearPendingState()
        playbackController.clearDrumKitPendingFeedback()

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
        session.activeArrangement = buildArrangement(for: reconciledAssignments)

        if snapshotDiffersFromPersistedJam(jam) {
            scheduleAutosave(debounce: .zero)
        }
    }

    private func closeSessionAndReturnToLibrary() {
        Task {
            await flushAutosave()
            clearTransportAndPlayback()
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
            effectSettings: PersistedJamEffectSettings(session.effectSettings)
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
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(currentDrumKitSubtitle)
                .font(.caption.weight(.medium))
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let detailText {
                        Text(detailText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(" ")
                            .font(.caption.weight(.medium))
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
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(activeEffectsDescription(activeCount: activeCount))
                    .font(.caption)
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(description)
                        .font(.caption)
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

    private var initialCoverImage: UIImage? {
        initialCoverData.flatMap(UIImage.init(data:))
    }

    private var selectedPhotoArea: some View {
        JamSelectedPhotoArea(
            session: session,
            visualTransport: visualTransport,
            sounds: library.items,
            coverDataByID: library.coverDataByID,
            reduceMotion: reduceMotion,
            changePhotosButton: { changePhotosButton() },
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
                    .font(isLarge ? .headline : .subheadline.weight(.semibold))
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
                    .font(.subheadline.weight(.semibold))
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
                    .font(.headline.weight(.semibold))
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
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            session.slotAssignments = next
            if session.isPlaying {
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
        buildArrangement(for: session.slotAssignments)
    }

    private func buildArrangement(for assignments: JamSlotAssignments) -> JamArrangement? {
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
            drumKit: drumKit
        )
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
    let sound: PhotoSound?
    let coverData: Data?
    let role: JamRole?
    let isActive: Bool
    let reduceMotion: Bool
    let photoColor: Color?
    let onDropPhotoID: (String) -> Void
    let onSwapForAccessibility: (JamRole, JamRole) -> Void

    @State private var targetedDropRole: JamRole?

    var body: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                coverImage
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(borderColor, lineWidth: borderWidth)
            }
            .overlay {
                if isHoverTarget {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill((photoColor ?? .primary).opacity(0.12))
                }
            }
            .overlay(alignment: .topLeading) {
                if let role {
                    Text(role.displayName)
                        .font(.caption2.weight(.semibold))
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
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.64), in: Capsule())
                        .padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(isActive ? 0.08 : 0))
            }
            .opacity(role == nil ? 0.58 : 1)
        .frame(maxWidth: .infinity)
        .modifier(JamTileDragAndDrop(
            role: role,
            photoID: sound?.id,
            targetedRole: $targetedDropRole,
            onDropPhotoID: onDropPhotoID
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(accessibilityValue)
        .modifier(JamTileAccessibilityActions(
            role: role,
            performSwap: { target in performSwapForAccessibility(target: target) }
        ))
    }

    private var isHoverTarget: Bool {
        targetedDropRole != nil
    }

    private var borderColor: Color {
        if isHoverTarget {
            return (photoColor ?? .primary).opacity(0.75)
        }
        if isActive {
            return .white.opacity(0.88)
        }

        return .white.opacity(role == nil ? 0.08 : 0.12)
    }

    private var borderWidth: CGFloat {
        if isHoverTarget { return 2 }
        return isActive ? 2 : 1
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
        if let coverData, let image = UIImage(data: coverData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Rectangle()
                .fill(.secondary.opacity(0.18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noteLabel: String {
        sound?.sequence.harmony.rootName ?? ""
    }

    private var accessibilityValue: String {
        if let role {
            return isActive ? "\(role.displayName), active on this step" : role.displayName
        }

        return sound == nil ? "Empty slot" : "No musical material"
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
    let changePhotosButton: () -> ChangePhotosButton
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
            reduceMotion: reduceMotion,
            photoColor: color,
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
                        .font(.caption2.weight(.semibold))
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

private enum JamControlPanel: Equatable {
    case none
    case kits
    case vibe
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(statusSecondaryText)
                    .font(.caption.weight(.medium))
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
                .font(.caption2.weight(.semibold))
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
    let onPanelToggle: (JamControlPanel) -> Void

    private static let tileSize: CGFloat = 68
    private static let tileSpacing: CGFloat = 12
    private static let cornerRadius: CGFloat = 18
    private static let iconSlotSize: CGFloat = 22

    var body: some View {
        HStack(spacing: Self.tileSpacing) {
            kitsTileButton
            vibeTileButton
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
                    .font(.caption2.weight(.semibold))
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
                    .font(.caption2.weight(.semibold))
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
                    .font(.caption2.weight(.semibold))
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
            .font(.footnote.weight(weight > 0.55 ? .bold : .semibold))
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
