import PaperShaders
import SwiftUI

struct PhotoPaperTextureModifier: ViewModifier {
    private let metrics = PaperEffectMetrics.active

    func body(content: Content) -> some View {
        content
            .paperTexture(
                color1: .white.opacity(metrics.lightGrainOpacity),
                color2: .black.opacity(metrics.darkGrainOpacity),
                density: metrics.grainDensity,
                scale: metrics.grainScale,
                lacunarity: metrics.grainLacunarity,
                gain: metrics.grainGain,
                octaves: metrics.grainOctaves
            )
    }
}

struct PhotoPaperOverlay: ViewModifier {
    let isMotionEnabled: Bool

    @State private var motionProvider = PhotoPaperMotionProvider()

    private var metrics: PaperEffectMetrics.Values {
        PaperEffectMetrics.active
    }

    func body(content: Content) -> some View {
        content
            .modifier(PhotoPaperTextureModifier())
            .overlay {
                GeometryReader { proxy in
                    if isMotionEnabled {
                        motionLighting(in: proxy.size)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                if isMotionEnabled {
                    motionProvider.start()
                }
            }
            .onDisappear {
                motionProvider.stop()
            }
            .onChange(of: isMotionEnabled) { _, isEnabled in
                if isEnabled {
                    motionProvider.start()
                } else {
                    motionProvider.stop()
                }
            }
    }

    private func motionLighting(in size: CGSize) -> some View {
        let highlightCenter = UnitPoint(
            x: clampedUnitPoint(
                0.5 + metrics.neutralHighlightX
                    + motionProvider.offset.width * metrics.horizontalTravelFraction
            ),
            y: clampedUnitPoint(
                0.5 + metrics.neutralHighlightY
                    + motionProvider.offset.height * metrics.verticalTravelFraction
            )
        )
        let shadowCenter = UnitPoint(
            x: clampedUnitPoint(
                0.5 - metrics.neutralHighlightX
                    - motionProvider.offset.width * metrics.horizontalTravelFraction
            ),
            y: clampedUnitPoint(
                0.5 - metrics.neutralHighlightY
                    - motionProvider.offset.height * metrics.verticalTravelFraction
            )
        )
        let highlightRadius = max(size.width, size.height) * metrics.highlightRadiusFraction
        let shadowRadius = max(size.width, size.height) * metrics.shadowRadiusFraction

        return ZStack {
            RadialGradient(
                stops: [
                    .init(color: .white.opacity(metrics.highlightOpacity), location: 0),
                    .init(color: .white.opacity(metrics.highlightOpacity * 0.35), location: 0.45),
                    .init(color: .clear, location: 1)
                ],
                center: highlightCenter,
                startRadius: 0,
                endRadius: highlightRadius
            )
            .blendMode(.screen)

            RadialGradient(
                stops: [
                    .init(color: .black.opacity(metrics.shadowOpacity), location: 0),
                    .init(color: .black.opacity(metrics.shadowOpacity * 0.35), location: 0.45),
                    .init(color: .clear, location: 1)
                ],
                center: shadowCenter,
                startRadius: 0,
                endRadius: shadowRadius
            )
            .blendMode(.multiply)
        }
    }

    private func clampedUnitPoint(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

enum PaperEffectMetrics {
    private static let usesPaperEffectCalibration = true

    struct Values {
        let lightGrainOpacity: Double
        let darkGrainOpacity: Double
        let grainDensity: CGFloat
        let grainScale: CGFloat
        let grainLacunarity: CGFloat
        let grainGain: CGFloat
        let grainOctaves: Int
        let highlightOpacity: Double
        let shadowOpacity: Double
        let highlightRadiusFraction: CGFloat
        let shadowRadiusFraction: CGFloat
        let horizontalTravelFraction: CGFloat
        let verticalTravelFraction: CGFloat
        let neutralHighlightX: CGFloat
        let neutralHighlightY: CGFloat
        let motionAngleLimit: Double
        let motionSmoothing: Double
        let motionDeadZone: Double
        let motionResponseExponent: Double
        let updateInterval: TimeInterval
        let motionPublishThreshold: CGFloat
    }

    static let normal = Values(
        lightGrainOpacity: 0.11,
        darkGrainOpacity: 0.08,
        grainDensity: 0.52,
        grainScale: 0.78,
        grainLacunarity: 1.55,
        grainGain: 0.56,
        grainOctaves: 3,
        highlightOpacity: 0.24,
        shadowOpacity: 0.12,
        highlightRadiusFraction: 0.72,
        shadowRadiusFraction: 0.82,
        horizontalTravelFraction: 0.30,
        verticalTravelFraction: 0.24,
        neutralHighlightX: -0.05,
        neutralHighlightY: -0.05,
        motionAngleLimit: 0.45,
        motionSmoothing: 0.22,
        motionDeadZone: 0.025,
        motionResponseExponent: 0.78,
        updateInterval: 1.0 / 30.0,
        motionPublishThreshold: 0.05
    )

    static let calibration = Values(
        lightGrainOpacity: 0.18,
        darkGrainOpacity: 0.14,
        grainDensity: 0.58,
        grainScale: 0.78,
        grainLacunarity: 1.55,
        grainGain: 0.56,
        grainOctaves: 3,
        highlightOpacity: 0.28,
        shadowOpacity: 0.16,
        highlightRadiusFraction: 0.82,
        shadowRadiusFraction: 0.92,
        horizontalTravelFraction: 0.38,
        verticalTravelFraction: 0.30,
        neutralHighlightX: -0.05,
        neutralHighlightY: -0.05,
        motionAngleLimit: 0.45,
        motionSmoothing: 0.24,
        motionDeadZone: 0.02,
        motionResponseExponent: 0.72,
        updateInterval: 1.0 / 30.0,
        motionPublishThreshold: 0.05
    )

    static var active: Values {
        usesPaperEffectCalibration ? calibration : normal
    }
}
