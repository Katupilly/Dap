import SwiftUI

struct JamSequencerSnapshot: Equatable, Sendable {
    let bassSteps: Set<Int>
    let harmonySteps: Set<Int>
    let melodySteps: Set<Int>

    init(arrangement: JamArrangement?, assignments: JamSlotAssignments) {
        self.init(
            activeStepsBySoundID: arrangement?.activeStepsBySoundID ?? [:],
            assignments: assignments
        )
    }

    private init(
        activeStepsBySoundID: [UUID: Set<Int>],
        assignments: JamSlotAssignments
    ) {
        let roleByID = assignments.assignedRolesByID
        var bassSteps: Set<Int> = []
        var harmonySteps: Set<Int> = []
        var melodySteps: Set<Int> = []

        for (soundID, steps) in activeStepsBySoundID {
            switch roleByID[soundID] {
            case .bass:
                bassSteps.formUnion(steps)
            case .harmony:
                harmonySteps.formUnion(steps)
            case .melody:
                melodySteps.formUnion(steps)
            case nil:
                break
            }
        }

        self.bassSteps = bassSteps
        self.harmonySteps = harmonySteps
        self.melodySteps = melodySteps
    }

    func steps(for role: JamRole) -> Set<Int> {
        switch role {
        case .bass: bassSteps
        case .harmony: harmonySteps
        case .melody: melodySteps
        }
    }
}

struct JamSequencerStatus: Equatable {
    let hasAnySelection: Bool
    let isPlaying: Bool
    let isApplyingNextBar: Bool
    let activeSlotCount: Int
    let reserveCount: Int
    let region: JamRegion
    let drumKit: MusicDrumKit
}

struct JamSequencerSnapshotHost: View {
    let steps: Int
    let session: JamSessionState
    let visualTransport: JamVisualTransportState
    let roleColors: [JamRole: Color]
    let reduceMotion: Bool

    var body: some View {
        let snapshot = JamSequencerSnapshot(
            arrangement: session.activeArrangement,
            assignments: session.slotAssignments
        )

        JamSequencerPlayheadReader(
            steps: steps,
            visualTransport: visualTransport,
            snapshot: snapshot,
            roleColors: roleColors,
            reduceMotion: reduceMotion
        )
    }
}

struct JamSequencerAndStatus<SequencerContent: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let status: JamSequencerStatus
    let bpm: Int
    let sequencerContent: SequencerContent

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
        if !status.hasAnySelection { return "READY" }
        if status.isApplyingNextBar { return "NEXT BAR" }
        return status.isPlaying ? "PLAYING" : "READY"
    }

    private var statusSecondaryText: String {
        if !status.hasAnySelection { return "ADD PHOTOS TO START" }
        if status.isApplyingNextBar { return "ARRANGEMENT CHANGE" }
        if status.isPlaying {
            return "\(regionDisplayName(status.region)) · \(drumKitDisplayName(status.drumKit))"
        }
        return "\(status.activeSlotCount) ACTIVE · \(status.reserveCount) IN BANK"
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

}

private struct JamSequencerPlayheadReader: View {
    let steps: Int
    let visualTransport: JamVisualTransportState
    let snapshot: JamSequencerSnapshot
    let roleColors: [JamRole: Color]
    let reduceMotion: Bool

    var body: some View {
        JamSequencerRows(
            steps: steps,
            currentStep: visualTransport.currentStep,
            snapshot: snapshot,
            roleColors: roleColors,
            reduceMotion: reduceMotion
        )
    }
}

private struct JamSequencerRows: View {
    let steps: Int
    let currentStep: Int?
    let snapshot: JamSequencerSnapshot
    let roleColors: [JamRole: Color]
    let reduceMotion: Bool

    var body: some View {
        JamSequencerGrid(
            steps: steps,
            currentStep: currentStep,
            snapshot: snapshot,
            roleColors: roleColors,
            reduceMotion: reduceMotion
        )
    }
}

private struct JamSequencerGrid: View {
    let steps: Int
    let currentStep: Int?
    let snapshot: JamSequencerSnapshot
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
        let activeSteps = snapshot.steps(for: role)
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
}
