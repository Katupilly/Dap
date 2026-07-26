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
                    kickSteps: [0, 8],
                    snareSteps: [4, 12],
                    closedHatSteps: [2, 6, 10, 14]
                ),
                MusicPercussionPattern(
                    kickSteps: [0, 10],
                    snareSteps: [4, 12],
                    closedHatSteps: [3, 7, 11, 15]
                ),
                MusicPercussionPattern(
                    kickSteps: [0, 11],
                    snareSteps: [8],
                    closedHatSteps: [2, 6, 10, 14]
                )
            ]
        case .bright:
            return [
                MusicPercussionPattern(
                    kickSteps: [0, 4, 8, 12],
                    snareSteps: [4, 12],
                    closedHatSteps: [0, 2, 4, 6, 8, 10, 12, 14]
                ),
                MusicPercussionPattern(
                    kickSteps: [0, 6, 8, 14],
                    snareSteps: [4, 12],
                    closedHatSteps: [0, 2, 4, 6, 8, 10, 12, 14]
                ),
                MusicPercussionPattern(
                    kickSteps: [0, 4, 8, 12],
                    snareSteps: [4, 12],
                    closedHatSteps: [1, 3, 5, 7, 9, 11, 13, 15]
                )
            ]
        case .deep:
            return [
                MusicPercussionPattern(
                    kickSteps: [0, 8, 12],
                    snareSteps: [4, 12],
                    closedHatSteps: [0, 4, 8, 12]
                ),
                MusicPercussionPattern(
                    kickSteps: [0, 7, 10],
                    snareSteps: [8],
                    closedHatSteps: [0, 4, 8, 12]
                ),
                MusicPercussionPattern(
                    kickSteps: [0, 3, 10],
                    snareSteps: [4, 12],
                    closedHatSteps: [0, 2, 6, 8, 10, 14]
                )
            ]
        case .intense:
            return [
                MusicPercussionPattern(
                    kickSteps: [0, 2, 6, 8, 10, 14],
                    snareSteps: [4, 12, 14],
                    closedHatSteps: [
                        0, 1, 2, 3,
                        4, 5, 6, 7,
                        8, 9, 10, 11,
                        12, 13, 14, 15
                    ]
                ),
                MusicPercussionPattern(
                    kickSteps: [0, 3, 7, 10, 14],
                    snareSteps: [4, 8, 12],
                    closedHatSteps: [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14]
                ),
                MusicPercussionPattern(
                    kickSteps: [0, 2, 5, 8, 10, 13],
                    snareSteps: [4, 7, 12, 15],
                    closedHatSteps: [
                        0, 1, 2, 3,
                        4, 5, 6, 7,
                        8, 9, 10, 11,
                        12, 13, 14, 15
                    ]
                )
            ]
        }
    }
}

private enum JamGrooveStyle {
    case airy
    case bright
    case deep
    case intense
}
