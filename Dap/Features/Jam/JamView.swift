import SwiftUI
import UIKit

struct JamView: View {
    let library: PhotoLibraryViewModel
    let isActive: Bool

    @State private var selectedSoundIDs: [UUID] = []
    @State private var vibePosition = CGPoint(x: 0.5, y: 0.5)
    @State private var isPhotoSelectorPresented = false
    @State private var isPlaying = false
    @State private var hasPendingArrangementChanges = false

    private var selectedSounds: [PhotoSound] {
        selectedSoundIDs.compactMap { id in
            library.items.first(where: { $0.id == id })
        }
    }

    private var playableSelectedSounds: [PhotoSound] {
        selectedSounds.filter { !$0.sequence.notes.isEmpty }
    }

    private var assignedSounds: [AssignedSound] {
        assignedSounds(for: playableSelectedSounds)
    }

    private var canPlay: Bool {
        !playableSelectedSounds.isEmpty
    }

    private var playbackAction: PlaybackAction {
        if isPlaying {
            return hasPendingArrangementChanges ? .update : .stop
        }

        return .play
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

                        VibeControl(position: $vibePosition) {
                            hasPendingArrangementChanges = true
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
            .sheet(isPresented: $isPhotoSelectorPresented) {
                JamPhotoSelectorSheet(
                    sounds: library.items,
                    coverDataByID: library.coverDataByID,
                    selectedSoundIDs: selectedSoundIDs,
                    isPresented: $isPhotoSelectorPresented,
                    onConfirmSelection: confirmPhotoSelection
                )
            }
            .onDisappear {
                stopPlayback()
            }
            .onChange(of: isActive) { _, isActive in
                guard !isActive else { return }
                stopPlayback()
            }
            .onChange(of: selectedSoundIDs) { _, newValue in
                let validIDs = newValue.filter { id in
                    library.items.contains(where: { $0.id == id })
                }

                if validIDs != newValue {
                    stopPlayback()
                    selectedSoundIDs = validIDs
                    hasPendingArrangementChanges = !validIDs.isEmpty
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Vibe")
                .font(.largeTitle.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

            if selectedSounds.isEmpty {
                Text("Choose up to three photos to build one shared arrangement.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if assignedSounds.isEmpty {
                Text("Selected photos do not contain musical material.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(roleSummary)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var roleSummary: String {
        assignedSounds.map {
            "\($0.role.displayName): \($0.sound.name ?? $0.sound.sequence.displayLabel)"
        }
        .joined(separator: "  ·  ")
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
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ForEach(assignedSounds) { assignedSound in
                    VStack(spacing: 10) {
                        Group {
                            if let coverData = library.coverDataByID[assignedSound.sound.id],
                               let image = UIImage(data: coverData) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle()
                                    .fill(.secondary.opacity(0.18))
                            }
                        }
                        .aspectRatio(4 / 5, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(spacing: 4) {
                            Text(assignedSound.role.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(assignedSound.sound.name ?? assignedSound.sound.sequence.displayLabel)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }

            Text("Shared key with fixed 96 BPM over one 16-step loop.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var playbackButton: some View {
        Button {
            switch playbackAction {
            case .play:
                startPlaybackIfPossible()
            case .stop:
                stopPlayback()
            case .update:
                updatePlaybackIfPossible()
            }
        } label: {
            Label(playbackAction.title, systemImage: playbackAction.systemImage)
                .font(.headline)
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
        guard stableSelection != selectedSoundIDs else { return }

        stopPlayback()
        selectedSoundIDs = stableSelection
        hasPendingArrangementChanges = !stableSelection.isEmpty
    }

    private func startPlaybackIfPossible() {
        guard let arrangement = buildArrangement() else {
            return
        }

        library.playTransientSequence(arrangement)
        isPlaying = true
        hasPendingArrangementChanges = false
    }

    private func updatePlaybackIfPossible() {
        guard let arrangement = buildArrangement() else {
            stopPlayback()
            return
        }

        library.stopTransientPlayback()
        library.playTransientSequence(arrangement)
        isPlaying = true
        hasPendingArrangementChanges = false
    }

    private func stopPlayback() {
        library.stopTransientPlayback()
        isPlaying = false
    }

    private func buildArrangement() -> MusicSequence? {
        let assignedSounds = assignedSounds(for: playableSelectedSounds)
        guard let melodySound = assignedSounds.first(where: { $0.role == .melody }) else {
            return nil
        }

        let preset = interpolatedPreset(for: vibePosition)
        let registerShift = quantizedRegisterShift(for: preset.registerBias)
        let harmony = globalHarmony(for: assignedSounds.map { $0.sound })
        let melodyProfile = melodySound.sound.sequence.soundProfile

        let notes = assignedSounds.flatMap { assignedSound in
            buildNotes(
                for: assignedSound,
                harmony: harmony,
                registerShift: registerShift
            )
        }
        .sorted {
            if $0.step != $1.step { return $0.step < $1.step }
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.midiNote < $1.midiNote
        }

        guard !notes.isEmpty else { return nil }

        return MusicSequence(
            harmony: MusicHarmony(
                rootPitchClass: harmony.rootPitchClass,
                scale: harmony.scale,
                bpm: 96
            ),
            notes: notes,
            soundProfile: SoundProfile(
                gate: preset.gate,
                octaveRange: melodyProfile.octaveRange,
                waveform: melodyProfile.waveform
            )
        )
    }

    private func buildNotes(
        for assignedSound: AssignedSound,
        harmony: GlobalHarmony,
        registerShift: Int
    ) -> [MusicNote] {
        let sourceNotes = sortedNotes(from: assignedSound.sound.sequence.notes)
        guard !sourceNotes.isEmpty else { return [] }

        switch assignedSound.role {
        case .bass:
            return buildBassNotes(
                from: sourceNotes,
                harmony: harmony,
                registerShift: registerShift
            )
        case .harmony:
            return buildHarmonyNotes(
                from: sourceNotes,
                harmony: harmony,
                registerShift: registerShift
            )
        case .melody:
            return buildMelodyNotes(
                from: sourceNotes,
                harmony: harmony,
                registerShift: registerShift
            )
        }
    }

    private func buildBassNotes(
        from sourceNotes: [MusicNote],
        harmony: GlobalHarmony,
        registerShift: Int
    ) -> [MusicNote] {
        let stepNotes = representativeNotesByStep(from: sourceNotes)
        let sampledNotes = sampledNotes(
            from: stepNotes,
            density: effectiveDensity(for: .bass, sourceCount: stepNotes.count)
        )

        let stablePitchClasses = [
            harmony.rootPitchClass,
            (harmony.rootPitchClass + 7) % 12
        ]

        var previousMIDINote: Int?

        return sampledNotes.map { note in
            let originalPitchClass = PitchClass(normalizing: note.midiNote).rawValue
            let chosenPitchClass = preferredBassPitchClass(
                for: originalPitchClass,
                rootPitchClass: harmony.rootPitchClass,
                fifthPitchClass: stablePitchClasses[1]
            )
            let targetMIDINote = bassMIDINote(
                pitchClass: chosenPitchClass,
                previousMIDINote: previousMIDINote,
                registerShift: registerShift
            )
            previousMIDINote = targetMIDINote

            return MusicNote(
                step: note.step,
                row: row(for: targetMIDINote),
                midiNote: targetMIDINote,
                velocity: transformedVelocity(
                    note.velocity,
                    multiplier: 0.70,
                    role: .bass
                )
            )
        }
    }

    private func buildHarmonyNotes(
        from sourceNotes: [MusicNote],
        harmony: GlobalHarmony,
        registerShift: Int
    ) -> [MusicNote] {
        let stepNotes = representativeNotesByStep(from: sourceNotes)
        let sampledNotes = sampledNotes(
            from: stepNotes,
            density: effectiveDensity(for: .harmony, sourceCount: stepNotes.count)
        )

        var previousMIDINote: Int?

        return sampledNotes.map { note in
            let scaleMIDINote = nearestScaleMIDINote(
                to: note.midiNote,
                rootPitchClass: harmony.rootPitchClass,
                scale: harmony.scale,
                range: 48...108
            )
            let targetMIDINote = centeredMIDINote(
                from: scaleMIDINote,
                preferredCenter: 66 + registerShift,
                previousMIDINote: previousMIDINote,
                range: 54...90
            )
            previousMIDINote = targetMIDINote

            return MusicNote(
                step: note.step,
                row: row(for: targetMIDINote),
                midiNote: targetMIDINote,
                velocity: transformedVelocity(
                    note.velocity,
                    multiplier: 0.55,
                    role: .harmony
                )
            )
        }
    }

    private func buildMelodyNotes(
        from sourceNotes: [MusicNote],
        harmony: GlobalHarmony,
        registerShift: Int
    ) -> [MusicNote] {
        let sampledNotes = sampledNotes(
            from: sourceNotes,
            density: effectiveDensity(for: .melody, sourceCount: sourceNotes.count)
        )

        return sampledNotes.map { note in
            let scaleMIDINote = nearestScaleMIDINote(
                to: note.midiNote,
                rootPitchClass: harmony.rootPitchClass,
                scale: harmony.scale,
                range: 48...108
            )
            let targetMIDINote = min(108, max(48, scaleMIDINote + registerShift))

            return MusicNote(
                step: note.step,
                row: row(for: targetMIDINote),
                midiNote: targetMIDINote,
                velocity: transformedVelocity(
                    note.velocity,
                    multiplier: 0.75,
                    role: .melody
                )
            )
        }
    }

    private func transformedVelocity(
        _ sourceVelocity: Float,
        multiplier: Float,
        role: JamRole
    ) -> Float {
        switch role {
        case .bass:
            return min(1.0, max(0.0, sourceVelocity * multiplier))
        case .harmony:
            return min(1.0, max(0.0, sourceVelocity * multiplier))
        case .melody:
            return min(1.0, max(0.0, sourceVelocity * multiplier))
        }
    }

    private func effectiveDensity(for role: JamRole, sourceCount: Int) -> Double {
        guard sourceCount > 0 else { return 0 }

        let globalDensity = interpolatedPreset(for: vibePosition).density
        let roleMultiplier: Double
        switch role {
        case .bass:
            roleMultiplier = 0.60
        case .harmony:
            roleMultiplier = 0.80
        case .melody:
            roleMultiplier = 1.00
        }

        let lowerBound = 1.0 / Double(sourceCount)
        return min(1.0, max(lowerBound, globalDensity * roleMultiplier))
    }

    private func sortedNotes(from notes: [MusicNote]) -> [MusicNote] {
        notes.sorted {
            if $0.step != $1.step { return $0.step < $1.step }
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.midiNote < $1.midiNote
        }
    }

    private func representativeNotesByStep(from notes: [MusicNote]) -> [MusicNote] {
        let notesByStep = Dictionary(grouping: notes, by: \.step)

        return notesByStep.keys
            .sorted()
            .compactMap { step in
                notesByStep[step]?
                    .sorted {
                        if $0.row != $1.row { return $0.row < $1.row }
                        return $0.midiNote < $1.midiNote
                    }
                    .first
            }
    }

    private func sampledNotes(from notes: [MusicNote], density: Double) -> [MusicNote] {
        guard !notes.isEmpty else { return [] }

        let targetCount = max(
            1,
            min(
                16,
                Int((Double(notes.count) * density).rounded())
            )
        )

        if targetCount >= notes.count {
            return notes
        }

        let sampled = (0..<targetCount).map { index in
            let sourceIndex = min(
                notes.count - 1,
                Int(
                    floor(
                        Double(index) *
                        Double(notes.count) /
                        Double(targetCount)
                    )
                )
            )

            return notes[sourceIndex]
        }

        return sampled.isEmpty ? [notes[0]] : sampled
    }

    private func assignedSounds(for sounds: [PhotoSound]) -> [AssignedSound] {
        let orderedSounds = sounds.sorted { lhs, rhs in
            let lhsRegister = averageRegister(for: lhs.sequence)
            let rhsRegister = averageRegister(for: rhs.sequence)

            if lhsRegister != rhsRegister { return lhsRegister < rhsRegister }
            if lhs.sequence.notes.count != rhs.sequence.notes.count {
                return lhs.sequence.notes.count < rhs.sequence.notes.count
            }

            return lhs.id.uuidString < rhs.id.uuidString
        }

        switch orderedSounds.count {
        case 3:
            return [
                AssignedSound(sound: orderedSounds[0], role: .bass),
                AssignedSound(sound: orderedSounds[1], role: .harmony),
                AssignedSound(sound: orderedSounds[2], role: .melody),
            ]
        case 2:
            return [
                AssignedSound(sound: orderedSounds[0], role: .bass),
                AssignedSound(sound: orderedSounds[1], role: .melody),
            ]
        case 1:
            guard let sound = orderedSounds.first else { return [] }
            return [AssignedSound(sound: sound, role: .melody)]
        default:
            return []
        }
    }

    private func averageRegister(for sequence: MusicSequence) -> Double {
        guard !sequence.notes.isEmpty else { return 48 }
        let total = sequence.notes.reduce(0) { $0 + $1.midiNote }
        return Double(total) / Double(sequence.notes.count)
    }

    private func globalHarmony(for sounds: [PhotoSound]) -> GlobalHarmony {
        let allNotes = sounds.flatMap { $0.sequence.notes }
        guard !allNotes.isEmpty else {
            let fallback = sounds.first?.sequence.harmony.rootPitchClass ?? 0
            return GlobalHarmony(rootPitchClass: fallback, scale: .majorPentatonic)
        }

        var histogram = Array(repeating: 0, count: 12)
        for note in allNotes {
            histogram[PitchClass(normalizing: note.midiNote).rawValue] += 1
        }

        var bestCandidate = GlobalHarmony(rootPitchClass: 0, scale: .majorPentatonic)
        var bestCoverage = Int.min

        for scale in [MusicScale.majorPentatonic, .minorPentatonic] {
            for root in 0..<12 {
                let coverage = scale.degrees
                    .map { (root + $0) % 12 }
                    .reduce(0) { $0 + histogram[$1] }

                if coverage > bestCoverage {
                    bestCoverage = coverage
                    bestCandidate = GlobalHarmony(rootPitchClass: root, scale: scale)
                    continue
                }

                guard coverage == bestCoverage else { continue }

                if bestCandidate.scale.rawValue == MusicScale.minorPentatonic.rawValue &&
                    scale.rawValue == MusicScale.majorPentatonic.rawValue {
                    bestCandidate = GlobalHarmony(rootPitchClass: root, scale: scale)
                } else if bestCandidate.scale.rawValue == scale.rawValue && root < bestCandidate.rootPitchClass {
                    bestCandidate = GlobalHarmony(rootPitchClass: root, scale: scale)
                }
            }
        }

        return bestCandidate
    }

    private func nearestScaleMIDINote(
        to midiNote: Int,
        rootPitchClass: Int,
        scale: MusicScale,
        range: ClosedRange<Int>
    ) -> Int {
        range
            .filter { candidate in
                let pitchClass = PitchClass(normalizing: candidate).rawValue
                return scale.degrees.contains((pitchClass - rootPitchClass + 12) % 12)
            }
            .min { lhs, rhs in
                let lhsDistance = abs(lhs - midiNote)
                let rhsDistance = abs(rhs - midiNote)

                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs < rhs
            } ?? min(range.upperBound, max(range.lowerBound, midiNote))
    }

    private func preferredBassPitchClass(
        for originalPitchClass: Int,
        rootPitchClass: Int,
        fifthPitchClass: Int
    ) -> Int {
        let rootDistance = pitchClassDistance(originalPitchClass, rootPitchClass)
        let fifthDistance = pitchClassDistance(originalPitchClass, fifthPitchClass)

        if rootDistance < fifthDistance { return rootPitchClass }
        if fifthDistance < rootDistance { return fifthPitchClass }
        return rootPitchClass
    }

    private func pitchClassDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, 12 - direct)
    }

    private func bassMIDINote(
        pitchClass: Int,
        previousMIDINote: Int?,
        registerShift: Int
    ) -> Int {
        let range = 48...72
        let preferredCenter = min(range.upperBound, max(range.lowerBound, 52 + registerShift))
        let candidates = range.filter { PitchClass(normalizing: $0).rawValue == pitchClass }

        return candidates.min { lhs, rhs in
            let lhsReference = previousMIDINote ?? preferredCenter
            let rhsReference = previousMIDINote ?? preferredCenter
            let lhsDistance = abs(lhs - lhsReference)
            let rhsDistance = abs(rhs - rhsReference)

            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }

            let lhsCenterDistance = abs(lhs - preferredCenter)
            let rhsCenterDistance = abs(rhs - preferredCenter)
            if lhsCenterDistance != rhsCenterDistance { return lhsCenterDistance < rhsCenterDistance }

            return lhs < rhs
        } ?? preferredCenter
    }

    private func centeredMIDINote(
        from midiNote: Int,
        preferredCenter: Int,
        previousMIDINote: Int?,
        range: ClosedRange<Int>
    ) -> Int {
        let pitchClass = PitchClass(normalizing: midiNote).rawValue
        let clampedCenter = min(range.upperBound, max(range.lowerBound, preferredCenter))
        let candidates = range.filter { PitchClass(normalizing: $0).rawValue == pitchClass }

        return candidates.min { lhs, rhs in
            let reference = previousMIDINote ?? clampedCenter
            let lhsDistance = abs(lhs - reference)
            let rhsDistance = abs(rhs - reference)

            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }

            let lhsCenterDistance = abs(lhs - clampedCenter)
            let rhsCenterDistance = abs(rhs - clampedCenter)
            if lhsCenterDistance != rhsCenterDistance { return lhsCenterDistance < rhsCenterDistance }

            return lhs < rhs
        } ?? min(range.upperBound, max(range.lowerBound, midiNote))
    }

    private func interpolatedPreset(for position: CGPoint) -> VibePreset {
        let x = min(max(position.x, 0), 1)
        let y = min(max(position.y, 0), 1)

        let wAiry = (1 - x) * (1 - y)
        let wBright = x * (1 - y)
        let wDeep = (1 - x) * y
        let wIntense = x * y

        return VibePreset(
            density: airyPreset.density * wAiry
                + brightPreset.density * wBright
                + deepPreset.density * wDeep
                + intensePreset.density * wIntense,
            registerBias: airyPreset.registerBias * wAiry
                + brightPreset.registerBias * wBright
                + deepPreset.registerBias * wDeep
                + intensePreset.registerBias * wIntense,
            gate: airyPreset.gate * wAiry
                + brightPreset.gate * wBright
                + deepPreset.gate * wDeep
                + intensePreset.gate * wIntense
        )
    }

    private func quantizedRegisterShift(for registerBias: Double) -> Int {
        let candidates = [-12, 0, 12]
        var bestCandidate = 0
        var bestDistance = Double.greatestFiniteMagnitude

        for candidate in candidates {
            let distance = abs(registerBias - Double(candidate))
            if distance < bestDistance {
                bestDistance = distance
                bestCandidate = candidate
                continue
            }

            guard distance == bestDistance else { continue }

            if candidate == 0 {
                bestCandidate = 0
            }
        }

        return bestCandidate
    }

    private func row(for midiNote: Int) -> Int {
        let normalized = Double(108 - min(108, max(48, midiNote))) / 60.0
        return min(7, max(0, Int((normalized * 7).rounded())))
    }
}

private struct JamPhotoSelectorSheet: View {
    let sounds: [PhotoSound]
    let coverDataByID: [UUID: Data]
    let selectedSoundIDs: [UUID]
    @Binding var isPresented: Bool
    let onConfirmSelection: ([UUID]) -> Void

    @State private var pendingSelectionIDs: Set<UUID> = []

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(sounds) { sound in
                        let isSelected = pendingSelectionIDs.contains(sound.id)
                        let canSelectMore = pendingSelectionIDs.count < 3 || isSelected

                        Button {
                            toggleSelection(for: sound.id)
                        } label: {
                            JamPhotoCell(
                                sound: sound,
                                coverData: coverDataByID[sound.id],
                                isSelected: isSelected,
                                isSelectable: canSelectMore
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Choose Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Photos") {
                        let stableSelection = pendingSelectionIDs.sorted { $0.uuidString < $1.uuidString }
                        onConfirmSelection(stableSelection)
                        isPresented = false
                    }
                    .disabled(pendingSelectionIDs.isEmpty)
                }
            }
            .onAppear {
                pendingSelectionIDs = Set(selectedSoundIDs)
            }
        }
    }

    private func toggleSelection(for id: UUID) {
        if pendingSelectionIDs.contains(id) {
            pendingSelectionIDs.remove(id)
        } else if pendingSelectionIDs.count < 3 {
            pendingSelectionIDs.insert(id)
        }
    }
}

private struct JamPhotoCell: View {
    let sound: PhotoSound
    let coverData: Data?
    let isSelected: Bool
    let isSelectable: Bool

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let coverData, let image = UIImage(data: coverData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.secondary.opacity(0.18))
                }
            }
            .aspectRatio(4 / 5, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 3)
            }

            Text(sound.name ?? sound.sequence.displayLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .opacity(isSelectable ? 1 : 0.45)
        .accessibilityLabel(sound.name ?? sound.sequence.displayLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}

private struct VibeControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var position: CGPoint
    let onPositionChanged: () -> Void

    @State private var lastQuadrant: Quadrant?
    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let handlePosition = CGPoint(
                x: clampedPosition.x * size.width,
                y: clampedPosition.y * size.height
            )

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.secondary.opacity(0.24), lineWidth: 1)

                crosshair

                cornerLabels

                Circle()
                    .fill(Color.primary)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Circle()
                            .stroke(Color(uiColor: .systemBackground), lineWidth: 3)
                    }
                    .shadow(color: .black.opacity(reduceMotion ? 0 : 0.12), radius: reduceMotion ? 0 : 10, y: reduceMotion ? 0 : 5)
                    .position(handlePosition)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
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
            .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
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
        let prominence = 0.45 + weight * 0.55

        return Text(title)
            .font(.footnote.weight(weight > 0.5 ? .bold : .semibold))
            .foregroundStyle(.secondary.opacity(prominence))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .systemBackground).opacity(0.72), in: Capsule())
            .scaleEffect(0.94 + weight * 0.08)
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
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .foregroundStyle(.white)
            .background(Color.black.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
    }
}

private enum PlaybackAction {
    case play
    case stop
    case update

    var title: String {
        switch self {
        case .play: "Play"
        case .stop: "Stop"
        case .update: "Update"
        }
    }

    var systemImage: String {
        switch self {
        case .play: "play.fill"
        case .stop: "stop.fill"
        case .update: "arrow.clockwise"
        }
    }
}

private enum JamRole: String, Equatable {
    case bass
    case harmony
    case melody

    var displayName: String {
        rawValue.capitalized
    }
}

private struct AssignedSound: Identifiable {
    let sound: PhotoSound
    let role: JamRole

    var id: UUID { sound.id }
}

private struct GlobalHarmony {
    let rootPitchClass: Int
    let scale: MusicScale
}

private struct VibePreset {
    let density: Double
    let registerBias: Double
    let gate: Double
}

private struct CornerWeights {
    let airy: CGFloat
    let bright: CGFloat
    let deep: CGFloat
    let intense: CGFloat
}

private let airyPreset = VibePreset(density: 0.40, registerBias: 7, gate: 0.72)
private let brightPreset = VibePreset(density: 0.72, registerBias: 12, gate: 0.42)
private let deepPreset = VibePreset(density: 0.34, registerBias: -12, gate: 0.78)
private let intensePreset = VibePreset(density: 0.82, registerBias: -5, gate: 0.34)
