import Foundation
import UIKit

struct JamStoryExportSnapshot {
    struct Photo: Identifiable {
        let id: UUID
        let role: JamRole?
        let title: String
        let noteLabel: String
        let image: UIImage?
        let accentColor: RGBColor
    }

    let jamName: String
    let coverDescriptor: JamCoverDescriptor
    let photos: [Photo]
    let sequencerSnapshot: JamSequencerSnapshot
    let roleColors: [JamRole: RGBColor]
    let region: JamRegion
    let drumKit: MusicDrumKit
    let bpm: Int
}

extension JamStoryExportSnapshot {
    static let fallbackAccent = RGBColor(red: 126, green: 134, blue: 164)
}
