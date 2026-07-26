import CoreGraphics
import Foundation

struct JamGrooveLibrary {
    func pattern(
        for vibePosition: CGPoint,
        soundIDs: [UUID]
    ) -> MusicPercussionPattern {
        let style = grooveStyle(for: vibePosition)
        let variants = patterns(for: style)
        let variantIndex = Int(
            stableSeed(for: soundIDs) % UInt64(variants.count)
        )
        return variants[variantIndex]
    }

    private func grooveStyle(for vibePosition: CGPoint) -> JamGrooveStyle {
        let x = min(max(vibePosition.x, 0), 1)
        let y = min(max(vibePosition.y, 0), 1)

        if x <= 0.5 {
            return y < 0.5 ? .airy : .deep
        } else {
            return y < 0.5 ? .bright : .intense
        }
    }

    private func stableSeed(
        for soundIDs: [UUID]
    ) -> UInt64 {
        guard !soundIDs.isEmpty else {
            return 0
        }

        var hash: UInt64 = 14_695_981_039_346_656_037

        for uuidString in soundIDs
            .map(\.uuidString)
            .sorted()
        {
            for byte in uuidString.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }

        return hash
    }

    private func patterns(for style: JamGrooveStyle) -> [MusicPercussionPattern] {
        switch style {
        case .airy:
            return [
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.96), hit(8, 0.72)],
                    snareHits: [hit(4, 0.84), hit(12, 0.88)],
                    closedHatHits: [hit(2, 0.62), hit(6, 0.42), hit(10, 0.58), hit(14, 0.46)],
                    openHatHits: [],
                    rimHits: []
                ),
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.94), hit(7, 0.68), hit(10, 0.74)],
                    snareHits: [hit(4, 0.82), hit(12, 0.86)],
                    closedHatHits: [hit(3, 0.56), hit(9, 0.62), hit(13, 0.44)],
                    openHatHits: [hit(15, 0.26)],
                    rimHits: []
                ),
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.95), hit(11, 0.66)],
                    snareHits: [hit(4, 0.84), hit(12, 0.88)],
                    closedHatHits: [hit(2, 0.60), hit(6, 0.40), hit(10, 0.52)],
                    openHatHits: [],
                    rimHits: [rim(7, 0.30, .soft), rim(15, 0.34, .soft)]
                )
            ]
        case .bright:
            return [
                MusicPercussionPattern(
                    kickHits: [hit(0, 1.00), hit(4, 0.90), hit(8, 0.96), hit(12, 0.90)],
                    snareHits: [hit(4, 0.90), hit(12, 0.94)],
                    closedHatHits: [hit(0, 0.80), hit(2, 0.48), hit(4, 0.74), hit(6, 0.52), hit(8, 0.82), hit(10, 0.50), hit(12, 0.76), hit(14, 0.54)],
                    openHatHits: [hit(7, 0.58)],
                    rimHits: []
                ),
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.99), hit(4, 0.88), hit(8, 0.95), hit(12, 0.88), hit(14, 0.68)],
                    snareHits: [hit(4, 0.88), hit(12, 0.92)],
                    closedHatHits: [hit(1, 0.42), hit(3, 0.72), hit(6, 0.48), hit(8, 0.78), hit(11, 0.50), hit(14, 0.70)],
                    openHatHits: [hit(7, 0.54)],
                    rimHits: [rim(10, 0.42, .main)]
                ),
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.99), hit(4, 0.88), hit(8, 0.96), hit(12, 0.90)],
                    snareHits: [hit(4, 0.89), hit(12, 0.95)],
                    closedHatHits: [hit(1, 0.44), hit(3, 0.74), hit(5, 0.42), hit(7, 0.78), hit(9, 0.48), hit(11, 0.68), hit(13, 0.46)],
                    openHatHits: [hit(14, 0.50)],
                    rimHits: [rim(15, 0.46, .main)]
                )
            ]
        case .deep:
            return [
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.98), hit(10, 0.74)],
                    snareHits: [hit(4, 0.92), hit(12, 0.94)],
                    closedHatHits: [hit(2, 0.46), hit(6, 0.58), hit(11, 0.42)],
                    openHatHits: [hit(14, 0.28)],
                    rimHits: [rim(3, 0.28, .soft)]
                ),
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.96), hit(7, 0.68), hit(13, 0.72)],
                    snareHits: [hit(8, 0.94)],
                    closedHatHits: [hit(1, 0.40), hit(4, 0.54), hit(10, 0.48), hit(14, 0.60)],
                    openHatHits: [],
                    rimHits: [rim(6, 0.34, .main), rim(15, 0.30, .soft)]
                ),
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.98), hit(3, 0.66), hit(10, 0.76)],
                    snareHits: [hit(4, 0.90), hit(12, 0.96)],
                    closedHatHits: [hit(2, 0.44), hit(6, 0.56), hit(9, 0.36), hit(14, 0.62)],
                    openHatHits: [hit(15, 0.28)],
                    rimHits: [rim(11, 0.38, .main)]
                )
            ]
        case .intense:
            return [
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.98), hit(3, 0.70), hit(8, 0.94), hit(10, 0.68), hit(14, 0.74)],
                    snareHits: [hit(4, 0.90), hit(12, 0.96)],
                    closedHatHits: [
                        hit(0, 0.78), hit(1, 0.42), hit(2, 0.66), hit(4, 0.74),
                        hit(6, 0.70), hit(7, 0.40), hit(8, 0.80), hit(9, 0.44),
                        hit(10, 0.72), hit(12, 0.76), hit(13, 0.46), hit(14, 0.68)
                    ],
                    openHatHits: [hit(11, 0.50)],
                    rimHits: [rim(15, 0.50, .hard)]
                ),
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.96), hit(2, 0.72), hit(6, 0.68), hit(8, 0.92), hit(11, 0.70), hit(14, 0.76)],
                    snareHits: [hit(4, 0.88), hit(12, 0.95)],
                    closedHatHits: [hit(0, 0.74), hit(2, 0.62), hit(3, 0.40), hit(5, 0.58), hit(6, 0.70), hit(8, 0.76), hit(10, 0.68), hit(11, 0.42), hit(13, 0.56), hit(15, 0.72)],
                    openHatHits: [hit(9, 0.46)],
                    rimHits: [rim(7, 0.44, .hard)]
                ),
                MusicPercussionPattern(
                    kickHits: [hit(0, 0.99), hit(2, 0.74), hit(5, 0.66), hit(8, 0.94), hit(10, 0.72), hit(13, 0.68)],
                    snareHits: [hit(4, 0.90), hit(7, 0.58), hit(12, 0.94)],
                    closedHatHits: [
                        hit(0, 0.80), hit(1, 0.40), hit(3, 0.62), hit(4, 0.74),
                        hit(6, 0.68), hit(7, 0.38), hit(8, 0.82), hit(10, 0.70),
                        hit(11, 0.44), hit(14, 0.76), hit(15, 0.36)
                    ],
                    openHatHits: [hit(9, 0.50)],
                    rimHits: [rim(15, 0.54, .hard)]
                )
            ]
        }
    }

    private func hit(_ step: Int, _ velocity: Float) -> MusicPercussionHit {
        MusicPercussionHit(step: step, velocity: velocity)
    }

    private func rim(_ step: Int, _ velocity: Float, _ style: MusicRimStyle) -> MusicRimHit {
        MusicRimHit(step: step, velocity: velocity, style: style)
    }
}

private enum JamGrooveStyle {
    case airy
    case bright
    case deep
    case intense
}
