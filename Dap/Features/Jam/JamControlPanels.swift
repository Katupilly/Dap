import SwiftUI
import UIKit

enum JamControlPanel: Equatable {
    case none
    case kits
    case vibe
    case arrange
    case effects
}


struct JamControlPanelHost<Content: View>: View {
    let selectedPanel: JamControlPanel
    let isPanelPresented: Bool
    let size: CGSize
    let bottomPadding: CGFloat
    let sizeAnimation: Animation
    let content: Content

    @ViewBuilder
    var body: some View {
        if isPanelPresented || selectedPanel != .none {
            ZStack(alignment: .bottom) {
                content
                    .scaleEffect(isPanelPresented ? 1 : 0.97, anchor: .bottom)
                    .opacity(isPanelPresented ? 1 : 0)
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity)
            .padding(.bottom, bottomPadding)
            .animation(sizeAnimation, value: selectedPanel)
            .allowsHitTesting(isPanelPresented)
        }
    }
}

struct JamKitsPanel: View {
    let selectedDrumKit: MusicDrumKitSelection
    let drumKitOptions: [MusicDrumKitSelection]
    let isDrumKitChangePending: Bool
    let isPreparedDrumKitChangePending: Bool
    let colorScheme: ColorScheme
    let currentDrumKitSubtitle: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let fill: Color
    let stroke: Color
    let onSelect: (MusicDrumKitSelection) -> Void

    var body: some View {
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
                ForEach(drumKitOptions, id: \.self) { selection in
                    drumKitOptionButton(selection)
                }
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 18)
        .frame(width: width, height: height, alignment: .topLeading)
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
        let isSelected = selectedDrumKit == selection
        let detailText: String? = if isSelected && isDrumKitChangePending {
            isPreparedDrumKitChangePending ? "Queued" : "Next bar"
        } else {
            nil
        }

        return Button {
            onSelect(selection)
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
                                : stroke,
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
                            : stroke,
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selection.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

}

enum MelodyPhraseIntent: String, CaseIterable, Identifiable {
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

enum JamArrangeOption: Hashable, Identifiable {
    case bass(BassPatternIntent)
    case harmony(HarmonyPatternIntent)
    case melody(MelodyPhraseIntent)

    var id: String {
        switch self {
        case .bass(let intent):
            return "bass-\(intent.rawValue)"
        case .harmony(let intent):
            return "harmony-\(intent.rawValue)"
        case .melody(let intent):
            return "melody-\(intent.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .bass(.steady): "STEADY"
        case .bass(.syncopated): "SYNCOPATED"
        case .bass(.driving): "DRIVING"
        case .harmony(.sustained): "SUSTAINED"
        case .harmony(.rhythmic): "RHYTHMIC"
        case .harmony(.open): "OPEN"
        case .melody(let intent): intent.title
        }
    }

    var subtitle: String {
        switch self {
        case .bass(.steady): "Anchored low-end"
        case .bass(.syncopated): "Offbeat accents"
        case .bass(.driving): "More forward motion"
        case .harmony(.sustained): "Longer chord holds"
        case .harmony(.rhythmic): "More chord attacks"
        case .harmony(.open): "Wider voicing spread"
        case .melody(let intent): intent.subtitle
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .bass(.steady): "Steady bass pattern"
        case .bass(.syncopated): "Syncopated bass pattern"
        case .bass(.driving): "Driving bass pattern"
        case .harmony(.sustained): "Sustained harmony pattern"
        case .harmony(.rhythmic): "Rhythmic harmony pattern"
        case .harmony(.open): "Open harmony pattern"
        case .melody(let intent): intent.accessibilityLabel
        }
    }
}

struct JamArrangePanelContext {
    let role: JamRole?
    let title: String
    let subtitle: String
    let options: [JamArrangeOption]
    let selectedOption: JamArrangeOption?
    let buttonTitle: String
    let isActionEnabled: Bool
}

enum JamArrangeAvailability {
    case available(JamRole)
    case noRoleSelected
    case roleHasNoPhoto(JamRole)
    case missingPhoto(JamRole)
    case roleHasNoMusicalMaterial(JamRole)
}

struct JamArrangePanel: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let subtitle: String
    let options: [JamArrangeOption]
    let selectedOption: JamArrangeOption?
    let buttonTitle: String
    let isActionEnabled: Bool
    let fill: Color
    let stroke: Color
    let onSelectOption: (JamArrangeOption) -> Void
    let onApply: () -> Void

    private let cornerRadius: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            if !options.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(options) { option in
                        optionButton(option)
                    }
                }
                .padding(.horizontal, 18)

                Button(action: onApply) {
                    Text(buttonTitle)
                        .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black.opacity(isActionEnabled ? 0.92 : 0.42))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(isActionEnabled ? 0.10 : 0.05), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(!isActionEnabled)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 18)
                .accessibilityLabel(buttonTitle.capitalized)
                .accessibilityHint("Applies a new arrangement variation for the selected role.")
            } else {
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
            Text(title)
                .font(.custom("ZTTalk-Bold", size: 20, relativeTo: .title3))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(subtitle)
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

    private func optionButton(_ option: JamArrangeOption) -> some View {
        let isSelected = selectedOption == option
        let selectedFill = colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.07)
        let selectedStroke = colorScheme == .dark
            ? Color.white.opacity(0.22)
            : Color.black.opacity(0.14)

        return Button {
            onSelectOption(option)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.title)
                    .font(.custom("ZTTalk-Bold", size: 13, relativeTo: .footnote))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(option.subtitle)
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
        .accessibilityLabel(option.accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct JamVibePanel: View {
    @Binding var vibePosition: CGPoint
    let expandedPanelFill: Color
    let expandedPanelStroke: Color
    let onPositionChanged: (CGPoint) -> Void
    let onPositionEnded: (CGPoint) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(expandedPanelFill)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(expandedPanelStroke, lineWidth: 1)
            VibeControl(
                position: $vibePosition,
                onPositionChanged: onPositionChanged,
                onPositionEnded: onPositionEnded
            )
        }
        .frame(width: 254, height: 254)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("Vibe control")
        .accessibilityValue(thumbnailLabel)
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

struct JamEffectsPanel: View {
    @Binding var effectSettings: JamEffectSettings
    let colorScheme: ColorScheme
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let fill: Color
    let stroke: Color

    var body: some View {
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
                    get: { effectSettings.reverbEnabled },
                    set: { effectSettings.reverbEnabled = $0 }
                ),
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
                isEnabled: Binding(
                    get: { effectSettings.delayEnabled },
                    set: { effectSettings.delayEnabled = $0 }
                ),
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
                isEnabled: Binding(
                    get: { effectSettings.lfoEnabled },
                    set: { effectSettings.lfoEnabled = $0 }
                ),
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
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(stroke, lineWidth: 1)
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
}

private struct VibeControl: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @Binding var position: CGPoint
    let onPositionChanged: (CGPoint) -> Void
    let onPositionEnded: (CGPoint) -> Void

    @State private var feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
    @GestureState private var isDragging = false
    @GestureState private var dragPosition: CGPoint? = nil
    @State private var lastMusicalQuadrant: Quadrant?

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
                    .updating($dragPosition) { value, state, _ in
                        state = normalizedPosition(for: value.location, in: size)
                    }
                    .onChanged { value in
                        let newPosition = normalizedPosition(for: value.location, in: size)
                        let newQuadrant = Quadrant(position: newPosition)
                        guard newQuadrant != lastMusicalQuadrant else { return }
                        lastMusicalQuadrant = newQuadrant
                        onPositionChanged(newPosition)
                    }
                    .onEnded { value in
                        let finalPosition = normalizedPosition(for: value.location, in: size)
                        lastMusicalQuadrant = nil
                        onPositionEnded(finalPosition)
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
        .accessibilityValue(currentQuadrant.displayName)
        .accessibilityHint("Drag to move between Airy, Bright, Deep, and Intense.")
        .accessibilityAction(named: "Move to Airy") {
            move(to: .topLeft)
        }
        .accessibilityAction(named: "Move to Bright") {
            move(to: .topRight)
        }
        .accessibilityAction(named: "Move to Deep") {
            move(to: .bottomLeft)
        }
        .accessibilityAction(named: "Move to Intense") {
            move(to: .bottomRight)
        }
    }

    private func move(to quadrant: Quadrant) {
        let finalPosition = quadrant.canonicalPosition
        onPositionEnded(finalPosition)
    }

    private var clampedPosition: CGPoint {
        let displayedPosition = dragPosition ?? position
        return CGPoint(
            x: min(max(displayedPosition.x, 0), 1),
            y: min(max(displayedPosition.y, 0), 1)
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

    var displayName: String {
        switch self {
        case .topLeft: "Airy"
        case .topRight: "Bright"
        case .bottomLeft: "Deep"
        case .bottomRight: "Intense"
        }
    }

    var canonicalPosition: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .bottomRight: CGPoint(x: 1, y: 1)
        }
    }
}


private struct CornerWeights {
    let airy: CGFloat
    let bright: CGFloat
    let deep: CGFloat
    let intense: CGFloat
}
