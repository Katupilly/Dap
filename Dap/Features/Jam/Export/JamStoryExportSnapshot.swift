import Foundation

enum JamStoryExportFormat: String, CaseIterable, Identifiable {
    case image
    case video

    var id: Self { self }

    var displayName: String {
        rawValue.capitalized
    }
}

struct JamStoryExportSnapshot: Sendable {
    struct Photo: Identifiable, Sendable {
        let id: UUID
        let role: JamRole?
        let title: String
        let noteLabel: String
        let imageData: Data?
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
    let arrangement: JamArrangement
    let effectSettings: JamEffectSettings
}

extension JamStoryExportSnapshot {
    static let fallbackAccent = RGBColor(red: 126, green: 134, blue: 164)
}
