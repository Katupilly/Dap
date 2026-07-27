import Foundation

enum JamRole: String, Equatable {
    case bass
    case harmony
    case melody

    var displayName: String {
        rawValue.capitalized
    }
}

struct AssignedSound: Identifiable, Equatable {
    let sound: PhotoSound
    let role: JamRole

    var id: UUID { sound.id }
}

/// Transient, view-owned role assignments for the active Jam slots.
///
/// This is the single source of truth for which selected photo currently
/// occupies Bass, Harmony, and Melody. `assignRoles(to:)` produces an initial
/// value once when the user confirms a selection; subsequent renders and
/// arrangement builds must read from this state instead of recomputing roles.
struct JamSlotAssignments: Equatable {
    var bass: UUID?
    var harmony: UUID?
    var melody: UUID?

    init(
        bass: UUID? = nil,
        harmony: UUID? = nil,
        melody: UUID? = nil
    ) {
        self.bass = bass
        self.harmony = harmony
        self.melody = melody
    }

    init(assignedSounds: [AssignedSound]) {
        self.init()

        for assignedSound in assignedSounds {
            switch assignedSound.role {
            case .bass:
                bass = assignedSound.sound.id
            case .harmony:
                harmony = assignedSound.sound.id
            case .melody:
                melody = assignedSound.sound.id
            }
        }
    }

    var activePhotoIDs: [UUID] {
        [bass, harmony, melody].compactMap { $0 }
    }

    var assignedRolesByID: [UUID: JamRole] {
        var result: [UUID: JamRole] = [:]
        if let bass { result[bass] = .bass }
        if let harmony { result[harmony] = .harmony }
        if let melody { result[melody] = .melody }
        return result
    }

    func pruningInvalidIDs(validIDs: Set<UUID>) -> JamSlotAssignments {
        let bass = bass.flatMap { validIDs.contains($0) ? $0 : nil }
        let harmony = harmony.flatMap { validIDs.contains($0) ? $0 : nil }
        let melody = melody.flatMap { validIDs.contains($0) ? $0 : nil }

        let survivors = [bass, harmony, melody].compactMap { $0 }

        switch survivors.count {
        case 3:
            return JamSlotAssignments(bass: bass, harmony: harmony, melody: melody)
        case 2:
            return Self.demotedAssignments(bass: bass, harmony: harmony, melody: melody)
        case 1:
            return JamSlotAssignments(melody: survivors[0])
        default:
            return JamSlotAssignments()
        }
    }

    private static func demotedAssignments(
        bass: UUID?,
        harmony: UUID?,
        melody: UUID?
    ) -> JamSlotAssignments {
        // If Melody survived, keep Bass and Melody as-is.
        if let bass, let melody {
            return JamSlotAssignments(bass: bass, melody: melody)
        }

        // If Bass was removed, Harmony takes its place.
        if let harmony, let melody {
            return JamSlotAssignments(bass: harmony, melody: melody)
        }

        // If Melody was removed, Harmony becomes Melody and Bass stays.
        if let bass, let harmony {
            return JamSlotAssignments(bass: bass, melody: harmony)
        }

        // Two survivors without a defined role pairing: keep their relative
        // musical function (smaller root becomes Bass, larger becomes Melody).
        let remaining = [bass, harmony, melody].compactMap { $0 }
        let sorted = remaining.sorted { $0.uuidString < $1.uuidString }
        return JamSlotAssignments(bass: sorted[0], melody: sorted[1])
    }
}
