import SwiftUI
import UIKit

private let jamStepsPerBar = MusicSequence.steps
private let jamBPM = 96.0
private let jamStepDuration = 60.0 / jamBPM / 4.0
private let jamBarDuration = jamStepDuration * Double(jamStepsPerBar)

struct JamView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let library: PhotoLibraryViewModel
    let isActive: Bool

    private let arrangementBuilder = JamArrangementBuilder(bpm: Int(jamBPM))

    @State private var slotAssignments = JamSlotAssignments()
    @State private var selectedPanel: JamControlPanel = .none
    @State private var isPanelPresented = false
    @State private var vibePosition = CGPoint(x: 0.5, y: 0.5)
    @State private var drumKitSelection: MusicDrumKitSelection = .auto
    @State private var isPhotoSelectorPresented = false
    @State private var isPlaying = false
    @State private var hasPendingArrangementChanges = false
    @State private var isDrumKitChangePending = false
    @State private var isPreparedDrumKitChangePending = false
    @State private var isDrumKitPendingIndicatorPulsing = false
    @State private var drumKitConfirmationPulseTrigger = 0
    @State private var swapArrangementVersion = 0
    @State private var effectSettings = JamEffectSettings.default
    @State private var currentStep: Int?
    @State private var activeSoundIDs: Set<UUID> = []
    @State private var activeArrangement: JamArrangement?
    @State private var transportTask: Task<Void, Never>?
    @State private var appliedArrangementVersion = 0

    private let panelDockGap: CGFloat = 14
    private let bottomReserve: CGFloat = 168
    private let dockHeight: CGFloat = 68
    private let dockBottomInset: CGFloat = 82
    private let playbackBottomInset: CGFloat = 16
    private let effectsPanelWidth: CGFloat = 352
    private let effectsPanelHeight: CGFloat = 392
    private let effectsPanelCornerRadius: CGFloat = 22

    private var selectedSounds: [PhotoSound] {
        slotAssignments.allPhotoIDs.compactMap { id in
            library.items.first(where: { $0.id == id })
        }
    }

    private var playableSelectedSounds: [PhotoSound] {
        selectedSounds.filter { !$0.sequence.notes.isEmpty }
    }

    private var assignedSounds: [AssignedSound] {
        let roleByID = slotAssignments.assignedRolesByID
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
        isPlaying ? .stop : .play
    }

    private var applyingNextBar: Bool {
        isPlaying && hasPendingArrangementChanges
    }

    private var resolvedDrumKitValue: MusicDrumKit {
        resolvedDrumKit(
            selection: drumKitSelection,
            region: JamGrooveLibrary.region(for: vibePosition)
        )
    }

    private var activeSlotCount: Int {
        slotAssignments.activePhotoIDs.count
    }

    private var reserveCount: Int {
        slotAssignments.reserve.count
    }

    private var currentRegion: JamRegion {
        JamGrooveLibrary.region(for: vibePosition)
    }

    private var statusPrimaryText: String {
        if selectedSounds.isEmpty { return "READY" }
        if applyingNextBar { return "NEXT BAR" }
        return isPlaying ? "PLAYING" : "READY"
    }

    private var statusSecondaryText: String {
        if selectedSounds.isEmpty { return "ADD PHOTOS TO START" }
        if applyingNextBar { return "ARRANGEMENT CHANGE" }
        if isPlaying {
            return "\(regionDisplayName(currentRegion)) · \(drumKitDisplayName(resolvedDrumKitValue))"
        }
        return "\(activeSlotCount) ACTIVE · \(reserveCount) IN BANK"
    }

    private var hasAnySelection: Bool {
        !selectedSounds.isEmpty
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

    private func photoColor(for role: JamRole) -> Color? {
        let roleID: UUID?
        switch role {
        case .bass: roleID = slotAssignments.bass
        case .harmony: roleID = slotAssignments.harmony
        case .melody: roleID = slotAssignments.melody
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
                    if hasAnySelection {
                        sequencerAndStatus
                    }

                    if selectedSounds.isEmpty {
                        emptyState
                    } else {
                        selectedPhotoArea
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomReserve)
                .frame(maxWidth: .infinity)
            }
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
                    vibePosition: $vibePosition,
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
        .sensoryFeedback(.selection, trigger: appliedArrangementVersion)
        .sensoryFeedback(.success, trigger: swapArrangementVersion)
        .onChange(of: effectSettings) { _, newSettings in
            let bpm = activeArrangement.map { Double($0.sequence.harmony.bpm) } ?? 96.0
            library.setJamEffects(newSettings, bpm: bpm)
        }
        .sheet(isPresented: $isPhotoSelectorPresented) {
            JamPhotoSelectorSheet(
                sounds: library.items,
                coverDataByID: library.coverDataByID,
                selectedPhotoIDs: slotAssignments.allPhotoIDs,
                isPresented: $isPhotoSelectorPresented,
                onConfirmSelection: confirmPhotoSelection
            )
        }
        .onAppear {
            library.setTransientLoopUpdatePreparedHandler {
                handlePreparedDrumKitLoopUpdate()
            }
        }
        .onDisappear {
            library.clearTransientLoopUpdatePreparedHandler()
            clearTransportAndPlayback()
        }
        .onChange(of: isActive) { _, isActive in
            guard !isActive else { return }
            clearTransportAndPlayback()
        }
        .onChange(of: library.items.map(\.id)) { _, itemIDs in
            let validIDs = Set(itemIDs)
            let playableIDs = Set(
                library.items.compactMap { sound in
                    sound.sequence.notes.isEmpty ? nil : sound.id
                }
            )
            let previousAssignments = slotAssignments
            let cleanedAssignments = slotAssignments.pruningInvalidIDs(
                validIDs: validIDs,
                playableIDs: playableIDs
            )

            guard cleanedAssignments != previousAssignments else { return }

            if isPlaying && cleanedAssignments.hasDifferentActiveSlots(from: previousAssignments) {
                hasPendingArrangementChanges = true
            }

            slotAssignments = cleanedAssignments
        }
        .onChange(of: library.isTransientPlaybackActive) { _, isActive in
            guard !isActive, isPlaying else { return }
            clearTransportState()
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
        case .vibe:
            vibePanelContent
        case .effects:
            effectsPanelContent
        case .none:
            Color.clear
        }
    }

    private var vibePanelContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            VibeControl(position: $vibePosition) {
                if isPlaying {
                    hasPendingArrangementChanges = true
                }
            }
        }
        .frame(width: 254, height: 254)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("Vibe control")
        .accessibilityValue(thumbnailLabel)
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
                isEnabled: $effectSettings.reverbEnabled,
                mixValue: Binding(
                    get: { Double(effectSettings.reverbMix) },
                    set: { effectSettings.reverbMix = Float($0) }
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
                isEnabled: $effectSettings.delayEnabled,
                mixValue: Binding(
                    get: { Double(effectSettings.delayMix) },
                    set: { effectSettings.delayMix = Float($0) }
                ),
                enableLabel: "Delay",
                mixLabel: "Delay Mix"
            )
            .padding(.horizontal, 18)

            effectRow(
                systemImage: "waveform.path",
                title: "LFO",
                description: "Tremolo · 1/2",
                isEnabled: $effectSettings.lfoEnabled,
                mixValue: Binding(
                    get: { Double(effectSettings.lfoAmount) },
                    set: { effectSettings.lfoAmount = Float($0) }
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
                .fill(Color(uiColor: .secondarySystemBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: effectsPanelCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Effect Rack")
    }

    private var activeEffectsCount: Int {
        var count = 0
        if effectSettings.reverbEnabled { count += 1 }
        if effectSettings.delayEnabled { count += 1 }
        if effectSettings.lfoEnabled { count += 1 }
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
                .fill(Color.primary.opacity(0.08))
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
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .frame(width: 38, height: 38)
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        enabled
                            ? Color.primary.opacity(0.10)
                            : Color.secondary.opacity(0.10)
                    )
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

    private var thumbnailLabel: String {
        switch JamGrooveLibrary.region(for: vibePosition) {
        case .airy: "Airy"
        case .bright: "Bright"
        case .deep: "Deep"
        case .intense: "Intense"
        }
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

    private var selectedPhotoArea: some View {
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
        let photoID = slotAssignments.photoID(for: role)
        let sound = photoID.flatMap { id in library.items.first(where: { $0.id == id }) }
        let isActive = photoID.map { activeSoundIDs.contains($0) } ?? false
        let color: Color? = photoColor(for: role)
        JamSelectedPhotoTile(
            sound: sound,
            coverData: sound.flatMap { library.coverDataByID[$0.id] },
            role: photoID == nil ? nil : role,
            isActive: photoID != nil && isActive,
            reduceMotion: reduceMotion,
            photoColor: color,
            onDropPhotoID: { droppedID in
                handleTileDrop(droppedID: droppedID, onto: role)
            },
            onSwapForAccessibility: { _, target in
                guard let photoID else { return }
                performSwapFromAccessibility(source: role, target: target, photoID: photoID)
            }
        )
        .id(role)
    }

    private var sequencerAndStatus: some View {
        JamSequencerAndStatus(
            steps: jamStepsPerBar,
            currentStep: currentStep,
            activeStepsBySoundID: activeArrangement?.activeStepsBySoundID ?? [:],
            roleByID: slotAssignments.assignedRolesByID,
            roleColors: rowColorMap,
            statusPrimaryText: statusPrimaryText,
            statusSecondaryText: statusSecondaryText,
            bpm: Int(jamBPM),
            isPending: applyingNextBar,
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
        Button {
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
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
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
        guard Set(confirmedIDs) != Set(slotAssignments.allPhotoIDs) else { return }

        let resolvedSounds = confirmedIDs.compactMap { id in
            library.items.first(where: { $0.id == id })
        }
        let playableSounds = resolvedSounds.filter { !$0.sequence.notes.isEmpty }
        let playableIDs = Set(playableSounds.map(\.id))
        let confirmedIDSet = Set(confirmedIDs)
        let survivingActiveIDs = slotAssignments.activePhotoIDs.filter { confirmedIDSet.contains($0) }

        let newAssignments: JamSlotAssignments
        if slotAssignments.allPhotoIDs.isEmpty || survivingActiveIDs.isEmpty {
            let initialAssigned = arrangementBuilder.assignRoles(to: playableSounds)
            newAssignments = JamSlotAssignments(
                assignedSounds: initialAssigned,
                allSelectedIDs: confirmedIDs
            )
        } else {
            newAssignments = slotAssignments.reconcilingSelection(
                selectedIDs: confirmedIDs,
                playableIDs: playableIDs
            )
        }

        let previousAssignments = slotAssignments
        guard newAssignments != previousAssignments else { return }

        slotAssignments = newAssignments
        if isPlaying && newAssignments.hasDifferentActiveSlots(from: previousAssignments) {
            hasPendingArrangementChanges = true
        }
    }

    private func handleTileDrop(droppedID: String, onto targetRole: JamRole?) {
        guard let targetRole,
              let parsedID = UUID(uuidString: droppedID),
              slotAssignments.activePhotoIDs.contains(parsedID) else {
            return
        }
        guard let sourceRole = slotAssignments.assignedRolesByID[parsedID] else {
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
              slotAssignments.photoID(for: source) == photoID else { return }
        applySwap(source: source, destination: target)
    }

    private func applySwap(source: JamRole, destination: JamRole) {
        guard source != destination else { return }
        let next = slotAssignments.swapping(source, destination)
        guard next != slotAssignments else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            slotAssignments = next
            if isPlaying {
                hasPendingArrangementChanges = true
            }
        }
        swapArrangementVersion += 1
    }

    private func selectDrumKit(_ selection: MusicDrumKitSelection) {
        guard selection != drumKitSelection else { return }
        drumKitSelection = selection

        guard isPlaying else {
            clearDrumKitPendingFeedback()
            return
        }

        beginDrumKitPendingFeedback()
        hasPendingArrangementChanges = true
    }

    private func startPlaybackIfPossible() {
        cancelTransportTask()

        guard let arrangement = buildArrangement() else {
            return
        }

        activeArrangement = arrangement
        library.playTransientSequence(
            arrangement.sequence,
            percussion: arrangement.percussion,
            loops: true
        )
        // Forward the current Effect Rack settings to the dedicated Jam chain.
        library.setJamEffects(effectSettings, bpm: Double(arrangement.sequence.harmony.bpm))
        updateStepState(step: 0, arrangement: arrangement)
        isPlaying = true
        hasPendingArrangementChanges = false
        clearDrumKitPendingFeedback()
        startTransportLoop()
    }

    private func clearTransportAndPlayback(clearPending: Bool = true) {
        cancelTransportTask()
        clearDrumKitPendingFeedback()
        library.stopTransientPlayback()
        activeArrangement = nil
        currentStep = nil
        activeSoundIDs = []
        isPlaying = false
        if clearPending {
            hasPendingArrangementChanges = false
        }
    }

    /// Clears only the Jam's local transport/UI state.
    /// Use when the underlying player has already been stopped
    /// externally (e.g. audio interruption) and we must not call `player.stop()` again.
    private func clearTransportState() {
        cancelTransportTask()
        clearDrumKitPendingFeedback()
        activeArrangement = nil
        currentStep = nil
        activeSoundIDs = []
        isPlaying = false
        hasPendingArrangementChanges = false
    }

    private func cancelTransportTask() {
        transportTask?.cancel()
        transportTask = nil
    }

    private func startTransportLoop() {
        cancelTransportTask()

        transportTask = Task { @MainActor in
            let clock = ContinuousClock()
            let stepInterval = Duration.seconds(jamStepDuration)
            var nextTick = clock.now.advanced(by: stepInterval)
            var step = 0

            while !Task.isCancelled && isPlaying {
                try? await clock.sleep(until: nextTick)
                guard !Task.isCancelled, isPlaying else { break }

                step = (step + 1) % jamStepsPerBar

                if step == 0 {
                    if hasPendingArrangementChanges {
                        guard let nextArrangement = buildArrangement() else {
                            clearDrumKitPendingFeedback()
                            clearTransportAndPlayback()
                            break
                        }

                        activeArrangement = nextArrangement
                        library.updateTransientLoop(
                            sequence: nextArrangement.sequence,
                            percussion: nextArrangement.percussion
                        )
                        hasPendingArrangementChanges = false
                        appliedArrangementVersion += 1
                        updateStepState(step: 0, arrangement: nextArrangement)
                        finishDrumKitPendingFeedbackIfNeeded()
                    } else if let activeArrangement {
                        updateStepState(step: 0, arrangement: activeArrangement)
                        finishDrumKitPendingFeedbackIfNeeded()
                    } else {
                        clearTransportAndPlayback()
                        break
                    }
                } else if let activeArrangement {
                    updateStepState(step: step, arrangement: activeArrangement)
                } else {
                    clearTransportAndPlayback()
                    break
                }

                nextTick = nextTick.advanced(by: stepInterval)
            }
        }
    }

    private func updateStepState(step: Int, arrangement: JamArrangement) {
        let activeIDs = Set(
            arrangement.activeStepsBySoundID.compactMap { soundID, steps in
                steps.contains(step) ? soundID : nil
            }
        )

        currentStep = step
        activeSoundIDs = activeIDs
    }

    private func buildArrangement() -> JamArrangement? {
        let region = JamGrooveLibrary.region(for: vibePosition)
        let drumKit = resolvedDrumKit(selection: drumKitSelection, region: region)

        return arrangementBuilder.build(
            assignedSounds: assignedSounds,
            vibePosition: vibePosition,
            drumKit: drumKit
        )
    }

    private func sendCurrentArrangementToPlayer() {
        guard let arrangement = buildArrangement() else {
            clearDrumKitPendingFeedback()
            clearTransportAndPlayback()
            return
        }

        hasPendingArrangementChanges = false
        isPreparedDrumKitChangePending = false
        activeArrangement = arrangement

        library.playTransientSequence(
            arrangement.sequence,
            percussion: arrangement.percussion,
            loops: true
        )
    }

    private func beginDrumKitPendingFeedback() {
        isPreparedDrumKitChangePending = false
        isDrumKitChangePending = true
        if !reduceMotion {
            isDrumKitPendingIndicatorPulsing = true
        }
    }

    private func handlePreparedDrumKitLoopUpdate() {
        guard isDrumKitChangePending else { return }
        isPreparedDrumKitChangePending = true
    }

    private func finishDrumKitPendingFeedbackIfNeeded() {
        guard isDrumKitChangePending, isPreparedDrumKitChangePending else { return }
        clearDrumKitPendingFeedback()
        drumKitConfirmationPulseTrigger += 1
    }

    private func clearDrumKitPendingFeedback() {
        isDrumKitChangePending = false
        isPreparedDrumKitChangePending = false
        isDrumKitPendingIndicatorPulsing = false
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
    case vibe
    case effects
}

private struct JamSequencerAndStatus: View {
    let steps: Int
    let currentStep: Int?
    let activeStepsBySoundID: [UUID: Set<Int>]
    let roleByID: [UUID: JamRole]
    let roleColors: [JamRole: Color]
    let statusPrimaryText: String
    let statusSecondaryText: String
    let bpm: Int
    let isPending: Bool
    let reduceMotion: Bool

    private static let rowOrder: [JamRole] = [.bass, .harmony, .melody]

    var body: some View {
        VStack(spacing: 0) {
            sequencerContent
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
                .padding(.horizontal, 14)

            statusContent
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(statusPrimaryText), \(statusSecondaryText), \(bpm) BPM")
    }

    private var sequencerContent: some View {
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
        let isPlayhead = step == currentStep
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
    @Binding var vibePosition: CGPoint
    let onPanelToggle: (JamControlPanel) -> Void

    private static let tileSize: CGFloat = 68
    private static let tileSpacing: CGFloat = 12
    private static let cornerRadius: CGFloat = 18

    var body: some View {
        HStack(spacing: Self.tileSpacing) {
            vibeTileButton
            effectsTileButton
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var vibeTileButton: some View {
        Button {
            onPanelToggle(.vibe)
        } label: {
            VibeDockTile(
                position: vibePosition,
                cornerRadius: Self.cornerRadius,
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
                isActive: selectedPanel == .effects && isPanelPresented
            )
        }
        .buttonStyle(.plain)
        .frame(width: Self.tileSize, height: Self.tileSize)
        .accessibilityLabel("Effects")
        .accessibilityValue("Empty")
    }

    private var thumbnailLabel: String {
        switch JamGrooveLibrary.region(for: vibePosition) {
        case .airy: "Airy"
        case .bright: "Bright"
        case .deep: "Deep"
        case .intense: "Intense"
        }
    }
}

private struct VibeDockTile: View {
    let position: CGPoint
    let cornerRadius: CGFloat
    var isActive: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(isActive ? 0.16 : 0.10))

            VStack(spacing: 3) {
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 18))
                        path.addLine(to: CGPoint(x: 36, y: 18))
                        path.move(to: CGPoint(x: 18, y: 0))
                        path.addLine(to: CGPoint(x: 18, y: 36))
                    }
                    .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

                    Circle()
                        .fill(Color.primary)
                        .frame(width: 6, height: 6)
                        .position(
                            x: min(max(position.x, 0), 1) * 36,
                            y: min(max(position.y, 0), 1) * 36
                        )
                }
                .frame(width: 36, height: 36)

                Text("Vibe")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(isActive ? 0.22 : 0.10), lineWidth: 1)
        }
    }
}

private struct EffectsDockTile: View {
    let cornerRadius: CGFloat
    var isActive: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(isActive ? 0.16 : 0.10))

            VStack(spacing: 3) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Effects")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(isActive ? 0.22 : 0.10), lineWidth: 1)
        }
    }
}

private struct VibeControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var position: CGPoint
    let onPositionChanged: () -> Void

    @State private var lastQuadrant: Quadrant?
    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    @GestureState private var isDragging = false

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
                        handleHaptics(for: newPosition)
                    }
                    .onEnded { value in
                        position = normalizedPosition(for: value.location, in: size)
                    }
            )
            .onAppear {
                feedbackGenerator.prepare()
                lastQuadrant = Quadrant(position: clampedPosition)
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
            .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
    }

    private var quadrantHighlights: some View {
        ZStack {
            LinearGradient(colors: [Color.white.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            LinearGradient(colors: [.clear, Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomLeading)
            LinearGradient(colors: [.clear, Color.white.opacity(0.03)], startPoint: .topTrailing, endPoint: .bottomTrailing)
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
            .background(Color(uiColor: .systemBackground).opacity(0.62), in: Capsule())
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

    private func handleHaptics(for position: CGPoint) {
        let quadrant = Quadrant(position: position)
        guard quadrant != lastQuadrant else { return }
        lastQuadrant = quadrant
        feedbackGenerator.impactOccurred()
        feedbackGenerator.prepare()
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
