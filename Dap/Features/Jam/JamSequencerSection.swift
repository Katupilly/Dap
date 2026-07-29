import SwiftUI

struct JamSequencerAndStatus: View {
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

    var body: some View {
        JamSequencerGrid(
            steps: steps,
            currentStep: visualTransport.currentStep,
            activeStepsBySoundID: activeStepsBySoundID,
            roleByID: roleByID,
            roleColors: roleColors,
            reduceMotion: reduceMotion
        )
    }
}

private struct JamSequencerGrid: View {
    let steps: Int
    let currentStep: Int?
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

    private func activeStepsForRole(_ role: JamRole) -> Set<Int> {
        var result: Set<Int> = []
        for (soundID, steps) in activeStepsBySoundID where roleByID[soundID] == role {
            result.formUnion(steps)
        }
        return result
    }
}

