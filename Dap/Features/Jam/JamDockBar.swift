import SwiftUI

struct JamDockBar: View {
    let selectedPanel: JamControlPanel
    let isPanelPresented: Bool
    let vibePosition: CGPoint
    let canOpenArrangePanel: Bool
    let arrangeAvailability: JamArrangeAvailability
    let onPanelToggle: (JamControlPanel) -> Void

    private static let tileSize: CGFloat = 62
    private static let tileSpacing: CGFloat = 8
    private static let cornerRadius: CGFloat = 18
    private static let iconSlotSize: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            let sideContainerWidth = (geometry.size.width - Self.tileSpacing) / 2
            let sideTileWidth = (sideContainerWidth - Self.tileSpacing) / 2

            HStack(spacing: Self.tileSpacing) {
                HStack(spacing: Self.tileSpacing) {
                    kitsTileButton(width: sideTileWidth)
                    vibeTileButton(width: sideTileWidth)
                }
                .frame(width: sideContainerWidth)

                HStack(spacing: Self.tileSpacing) {
                    arrangeTileButton(width: sideTileWidth)
                    effectsTileButton(width: sideTileWidth)
                }
                .frame(width: sideContainerWidth)
            }
        }
        .frame(height: Self.tileSize)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func kitsTileButton(width: CGFloat) -> some View {
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
        .frame(width: width, height: Self.tileSize)
        .accessibilityLabel("Kits")
        .accessibilityValue("\(selectedPanel == .kits && isPanelPresented ? "Expanded" : "Collapsed")")
    }

    private func vibeTileButton(width: CGFloat) -> some View {
        Button {
            onPanelToggle(.vibe)
        } label: {
            VibeDockTile(
                position: vibePosition,
                cornerRadius: Self.cornerRadius,
                iconSlotSize: Self.iconSlotSize,
                isActive: selectedPanel == .vibe && isPanelPresented
            )
        }
        .buttonStyle(.plain)
        .frame(width: width, height: Self.tileSize)
        .accessibilityLabel("Vibe")
        .accessibilityValue(thumbnailLabel)
    }

    private func arrangeTileButton(width: CGFloat) -> some View {
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
        .frame(width: width, height: Self.tileSize)
        .accessibilityLabel("Arrange")
        .accessibilityValue(arrangeAccessibilityValue)
        .accessibilityHint(arrangeAccessibilityHint)
    }

    private func effectsTileButton(width: CGFloat) -> some View {
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
        .frame(width: width, height: Self.tileSize)
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

    private var arrangeAccessibilityValue: String {
        if selectedPanel == .arrange && isPanelPresented {
            return "Expanded"
        }
        switch arrangeAvailability {
        case .available(let role):
            return "Available for \(role.displayName)"
        case .noRoleSelected:
            return "No role selected"
        case .roleHasNoPhoto(let role):
            return "\(role.displayName) has no photo"
        case .missingPhoto(let role):
            return "\(role.displayName) photo unavailable"
        case .roleHasNoMusicalMaterial(let role):
            return "\(role.displayName) has no musical material"
        }
    }

    private var arrangeAccessibilityHint: String {
        switch arrangeAvailability {
        case .available(.bass):
            return "Open Arrange for the selected Bass photo."
        case .available(.harmony):
            return "Open Arrange for the selected Harmony photo."
        case .available(.melody):
            return "Open Arrange for the selected Melody photo."
        case .noRoleSelected:
            return "Select a playable Bass, Harmony, or Melody photo to use Arrange."
        case .roleHasNoPhoto(let role):
            return "Select a photo for \(role.displayName) to use Arrange."
        case .missingPhoto(let role):
            return "The selected \(role.displayName) photo is no longer available."
        case .roleHasNoMusicalMaterial(let role):
            return "The selected \(role.displayName) photo has no musical material to arrange."
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
