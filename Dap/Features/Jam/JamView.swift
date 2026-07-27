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
    @State private var vibePosition = CGPoint(x: 0.5, y: 0.5)
    @State private var drumKitSelection: MusicDrumKitSelection = .auto
    @State private var isPhotoSelectorPresented = false
    @State private var isPlaying = false
    @State private var hasPendingArrangementChanges = false
    @State private var isDrumKitChangePending = false
    @State private var isPreparedDrumKitChangePending = false
    @State private var isDrumKitPendingIndicatorPulsing = false
    @State private var drumKitConfirmationPulseTrigger = 0
    @State private var currentStep: Int?
    @State private var activeSoundIDs: Set<UUID> = []
    @State private var activeArrangement: JamArrangement?
    @State private var transportTask: Task<Void, Never>?
    @State private var appliedArrangementVersion = 0

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

    private var selectedPhotoCountSummary: String {
        switch slotAssignments.allPhotoIDs.count {
        case 1:
            return "1 photo"
        case 2:
            return "2 photos"
        case 3:
            return "3 photos"
        default:
            return "Select up to 3 photos"
        }
    }

    private var presentedSelectedSounds: [PresentedJamSound] {
        let selectionIDSet = Set(slotAssignments.allPhotoIDs)
        let orderedAssigned: [(UUID?, JamRole)] = [
            (slotAssignments.bass, .bass),
            (slotAssignments.harmony, .harmony),
            (slotAssignments.melody, .melody)
        ]

        let arranged = orderedAssigned.compactMap { id, role -> PresentedJamSound? in
            guard let id, selectionIDSet.contains(id),
                  let sound = library.items.first(where: { $0.id == id }) else {
                return nil
            }
            return PresentedJamSound(sound: sound, role: role)
        }

        let assignedIDs = Set(arranged.map(\.sound.id))
        let unassignedSounds = selectedSounds
            .filter { !assignedIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { PresentedJamSound(sound: $0, role: nil) }

        return arranged + unassignedSounds
    }

    private var transportStatusTitle: String {
        if !isPlaying {
            return "Ready"
        }

        return applyingNextBar ? "Next bar" : "Playing"
    }

    private var transportStatusAccessibilityLabel: String {
        if applyingNextBar {
            return "Changes queued for next bar"
        }

        return transportStatusTitle
    }

    private var drumKitControlTitle: String {
        "Drum Kit · \(drumKitSelection.displayName)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    if selectedSounds.isEmpty {
                        emptyState
                    } else {
                        selectedPhotoPreview
                        transportStrip
                        drumKitControl

                        VibeControl(position: $vibePosition) {
                            if isPlaying {
                                hasPendingArrangementChanges = true
                            }
                        }

                        playbackButton
                        photoButton(title: "Change Photos")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: appliedArrangementVersion)
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
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Vibe")
                .font(.largeTitle.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(selectedPhotoCountSummary) · 96 BPM · 16-step loop")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: selectedPhotoCountSummary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            ContentUnavailableView(
                "Choose one to three photos to shape the jam vibe.",
                systemImage: "waveform.path.ecg"
            )
            .frame(maxWidth: .infinity)

            photoButton(title: "Add Photo")
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private var selectedPhotoPreview: some View {
        HStack(spacing: 12) {
            ForEach(presentedSelectedSounds) { presentedSound in
                JamSelectedPhotoTile(
                    sound: presentedSound.sound,
                    coverData: library.coverDataByID[presentedSound.sound.id],
                    role: presentedSound.role,
                    isActive: presentedSound.role != nil && activeSoundIDs.contains(presentedSound.sound.id),
                    reduceMotion: reduceMotion
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var transportStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(transportStatusTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPlaying ? .primary : .secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: transportStatusTitle)

            HStack(spacing: 4) {
                ForEach(0..<jamStepsPerBar, id: \.self) { step in
                    Capsule(style: .continuous)
                        .fill(step == currentStep ? Color.primary : Color.secondary.opacity(isPlaying ? 0.22 : 0.12))
                        .frame(maxWidth: .infinity)
                        .frame(height: 6)
                        .animation(.easeInOut(duration: jamStepDuration * 0.35), value: currentStep)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transportStatusAccessibilityLabel)
    }

    private var drumKitControl: some View {
        Menu {
            ForEach(MusicDrumKitSelection.allCases, id: \.self) { selection in
                Button {
                    selectDrumKit(selection)
                } label: {
                    drumKitMenuItemLabel(for: selection)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(drumKitControlTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if isDrumKitChangePending {
                    HStack(spacing: 4) {
                        Circle()
                            .frame(width: 5, height: 5)
                            .opacity(reduceMotion ? 0.7 : (isDrumKitPendingIndicatorPulsing ? 0.9 : 0.45))
                            .accessibilityHidden(true)

                        Text("Next bar")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.white.opacity(0.65))
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.94))
                    )
                }

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .opacity(0.72)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(.white)
            .glassEffect(
                .regular
                    .tint(
                        Color(
                            red: 26.0 / 255.0,
                            green: 26.0 / 255.0,
                            blue: 30.0 / 255.0
                        )
                        .opacity(0.78)
                    )
                    .interactive(true),
                in: Capsule()
            )
            .contentShape(.interaction, Capsule())
            .phaseAnimator([false, true, false], trigger: drumKitConfirmationPulseTrigger) { content, phase in
                content
                    .scaleEffect(reduceMotion ? 1 : (phase ? 1.025 : 1))
                    .opacity(reduceMotion && phase ? 0.92 : 1)
            } animation: { phase in
                phase ? .easeInOut(duration: 0.09) : .easeInOut(duration: 0.09)
            }
            .animation(.easeInOut(duration: 0.18), value: isDrumKitChangePending)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: isDrumKitPendingIndicatorPulsing
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Drum Kit, \(drumKitSelection.displayName)")
        .accessibilityValue(isDrumKitChangePending ? "Changes next bar" : "Active")
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
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(JamPrimaryButtonStyle())
        .disabled(!canPlay)
    }

    private func photoButton(title: String) -> some View {
        Button(title) {
            isPhotoSelectorPresented = true
        }
        .buttonStyle(JamSecondaryButtonStyle())
        .frame(maxWidth: .infinity)
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

    private func selectDrumKit(_ selection: MusicDrumKitSelection) {
        guard selection != drumKitSelection else { return }
        drumKitSelection = selection

        guard isPlaying else {
            clearDrumKitPendingFeedback()
            return
        }

        beginDrumKitPendingFeedback()
        sendCurrentArrangementToPlayer()
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
                        library.playTransientSequence(
                            nextArrangement.sequence,
                            percussion: nextArrangement.percussion,
                            loops: true
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

        if reduceMotion {
            currentStep = step
            activeSoundIDs = activeIDs
        } else {
            withAnimation(.easeInOut(duration: jamStepDuration * 0.6)) {
                currentStep = step
                activeSoundIDs = activeIDs
            }
        }
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
            case .airy:
                .soft
            case .bright:
                .club
            case .deep:
                .breakbeat
            case .intense:
                .metal
            }
        case .soft:
            .soft
        case .club:
            .club
        case .breakbeat:
            .breakbeat
        case .metal:
            .metal
        }
    }

    @ViewBuilder
    private func drumKitMenuItemLabel(for selection: MusicDrumKitSelection) -> some View {
        if selection == drumKitSelection {
            Label(selection.displayName, systemImage: "checkmark")
        } else {
            Text(selection.displayName)
        }
    }
}

private struct JamSelectedPhotoTile: View {
    let sound: PhotoSound
    let coverData: Data?
    let role: JamRole?
    let isActive: Bool
    let reduceMotion: Bool

    var body: some View {
        Color.clear
            .aspectRatio(4.0 / 5.0, contentMode: .fit)
            .overlay {
                coverImage
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(borderColor, lineWidth: isActive ? 2 : 1)
            }
            .overlay(alignment: .topLeading) {
                if let role {
                    Text(role.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(isActive ? 0.08 : 0))
            }
            .opacity(role == nil ? 0.58 : 1)
            .scaleEffect(reduceMotion ? 1 : (isActive ? 1.03 : 1.0))
            .animation(reduceMotion ? nil : .easeInOut(duration: jamStepDuration * 0.6), value: isActive)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sound.name ?? sound.sequence.displayLabel)
        .accessibilityValue(accessibilityValue)
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

    private var borderColor: Color {
        if isActive {
            return .white.opacity(0.88)
        }

        return .white.opacity(role == nil ? 0.08 : 0.12)
    }

    private var accessibilityValue: String {
        if let role {
            return isActive ? "\(role.displayName), active on this step" : role.displayName
        }

        return "No musical material"
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
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))

                quadrantHighlights

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)

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
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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

private struct JamPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 17)
            .padding(.horizontal, 18)
            .foregroundStyle(.white)
            .background(Color.black.opacity(configuration.isPressed ? 0.9 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct JamSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .foregroundStyle(.primary)
            .background(Color.secondary.opacity(configuration.isPressed ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

private enum PlaybackAction {
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

private struct PresentedJamSound: Identifiable {
    let sound: PhotoSound
    let role: JamRole?

    var id: UUID { sound.id }
}
