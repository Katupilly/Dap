import SwiftUI
import UIKit

private struct JamSelectedPhotoTile: View {
    @Environment(\.colorScheme) private var colorScheme

    let sound: PhotoSound?
    let image: UIImage?
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
            .accessibilityAction(.default) {
                onTap()
            }
            .accessibilityAddTraits(.isButton)
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
            if let image {
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
        return "Selects the \(role.displayName) role for arrange controls"
    }
}

struct JamSelectedPhotoAreaHost<ChangePhotosButton: View>: View {
    let visualTransport: JamVisualTransportState
    let assignments: JamSlotAssignments
    let sounds: [PhotoSound]
    let imagesByID: [UUID: UIImage]
    let reduceMotion: Bool
    let selectedJamRole: JamRole?
    let changePhotosButton: () -> ChangePhotosButton
    let onTapRole: (JamRole?) -> Void
    let onDropPhotoID: (String, JamRole?) -> Void
    let onSwapForAccessibility: (JamRole, JamRole, UUID) -> Void

    var body: some View {
        JamSelectedPhotoArea(
            assignments: assignments,
            activeSoundIDs: visualTransport.activeSoundIDs,
            sounds: sounds,
            imagesByID: imagesByID,
            reduceMotion: reduceMotion,
            selectedJamRole: selectedJamRole,
            changePhotosButton: changePhotosButton,
            onTapRole: onTapRole,
            onDropPhotoID: onDropPhotoID,
            onSwapForAccessibility: onSwapForAccessibility
        )
    }
}

private struct JamSelectedPhotoArea<ChangePhotosButton: View>: View {
    let assignments: JamSlotAssignments
    let activeSoundIDs: Set<UUID>
    let sounds: [PhotoSound]
    let imagesByID: [UUID: UIImage]
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
        let photoID = assignments.photoID(for: role)
        let sound = photoID.flatMap { id in sounds.first(where: { $0.id == id }) }
        let isActive = photoID.map { activeSoundIDs.contains($0) } ?? false
        let color = photoColor(for: role)

        JamSelectedPhotoTile(
            sound: sound,
            image: sound.flatMap { imagesByID[$0.id] },
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
        guard let roleID = assignments.photoID(for: role),
              let sound = sounds.first(where: { $0.id == roleID })
        else { return nil }
        let pitch = PitchClass(rawValue: sound.sequence.harmony.rootPitchClass) ?? .c
        return Color(jamRGB: RetroCoverRenderer.tonalPalette(for: pitch).base)
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

struct JamTileVisualStyle {
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

    fileprivate func playbackImpulseScale(for phase: PlaybackImpulsePhase) -> CGFloat {
        switch phase {
        case .rest:
            1
        case .lifted:
            1 + playingImpulseScaleDelta
        case .settled:
            1
        }
    }

    fileprivate func playbackImpulseYOffset(for phase: PlaybackImpulsePhase) -> CGFloat {
        switch phase {
        case .rest:
            0
        case .lifted:
            playingImpulseYOffset
        case .settled:
            0
        }
    }

    fileprivate func playbackImpulseShadowColor(for phase: PlaybackImpulsePhase) -> Color {
        switch phase {
        case .lifted:
            playingImpulseShadowColor
        case .rest, .settled:
            .clear
        }
    }

    fileprivate func playbackImpulseShadowRadius(for phase: PlaybackImpulsePhase) -> CGFloat {
        phase == .lifted ? playingImpulseShadowRadius : 0
    }

    fileprivate func playbackImpulseShadowYOffset(for phase: PlaybackImpulsePhase) -> CGFloat {
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
