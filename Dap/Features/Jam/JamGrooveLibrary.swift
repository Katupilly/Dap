import CoreGraphics

struct JamGrooveLibrary {
    func pattern(
        for vibePosition: CGPoint
    ) -> MusicPercussionPattern {
        let style = grooveStyle(for: vibePosition)
        return percussionPattern(for: style)
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

    private func percussionPattern(for style: JamGrooveStyle) -> MusicPercussionPattern {
        switch style {
        case .airy:
            return MusicPercussionPattern(
                kickSteps: [0, 8],
                snareSteps: [4, 12],
                closedHatSteps: [2, 6, 10, 14]
            )
        case .bright:
            return MusicPercussionPattern(
                kickSteps: [0, 4, 8, 12],
                snareSteps: [4, 12],
                closedHatSteps: [0, 2, 4, 6, 8, 10, 12, 14]
            )
        case .deep:
            return MusicPercussionPattern(
                kickSteps: [0, 8, 12],
                snareSteps: [4, 12],
                closedHatSteps: [0, 4, 8, 12]
            )
        case .intense:
            return MusicPercussionPattern(
                kickSteps: [0, 2, 6, 8, 10, 14],
                snareSteps: [4, 12, 14],
                closedHatSteps: [
                    0, 1, 2, 3,
                    4, 5, 6, 7,
                    8, 9, 10, 11,
                    12, 13, 14, 15
                ]
            )
        }
    }
}

private enum JamGrooveStyle {
    case airy
    case bright
    case deep
    case intense
}
