import Foundation

/// Configuration for the global Jam Effect Rack.
///
/// All three effects start disabled. When disabled, the corresponding
/// DSP stage is bypassed (Reverb/Delay wetDryMix = 0, LFO gain stage = 1).
struct JamEffectSettings: Equatable, Sendable {
    var reverbEnabled: Bool
    var reverbMix: Float

    var delayEnabled: Bool
    var delayMix: Float

    var lfoEnabled: Bool
    var lfoAmount: Float

    static let `default` = JamEffectSettings(
        reverbEnabled: false,
        reverbMix: 0.28,
        delayEnabled: false,
        delayMix: 0.22,
        lfoEnabled: false,
        lfoAmount: 0.35
    )
}
