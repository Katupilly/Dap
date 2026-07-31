import Foundation

enum JamRole: String, Equatable, CaseIterable, Sendable {
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

/// Transient, view-owned Jam membership and role assignments.
///
/// This is the single source of truth for which selected photo currently
/// occupies Bass, Harmony, and Melody, plus which selected photos remain in
/// reserve. `assignRoles(to:)` produces an initial active assignment once when
/// the user confirms a fresh selection; subsequent renders and arrangement
/// builds must read from this state instead of recomputing roles.
struct JamSlotAssignments: Equatable {
    static let maximumPhotoCount = 3

    var bass: UUID?
    var harmony: UUID?
    var melody: UUID?
    var reserve: [UUID]

    init(
        bass: UUID? = nil,
        harmony: UUID? = nil,
        melody: UUID? = nil,
        reserve: [UUID] = []
    ) {
        self.bass = bass
        self.harmony = harmony
        self.melody = melody
        self.reserve = reserve
    }

    init(assignedSounds: [AssignedSound], allSelectedIDs: [UUID]) {
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

        let activeIDs = activePhotoIDs
        reserve = Self.orderedUnique(
            allSelectedIDs.filter { id in
                !activeIDs.contains(id)
            }
        )
    }

    var activePhotoIDs: [UUID] {
        [bass, harmony, melody].compactMap { $0 }
    }

    var allPhotoIDs: [UUID] {
        activePhotoIDs + reserve
    }

    var availablePhotoCount: Int {
        max(Self.maximumPhotoCount - allPhotoIDs.count, 0)
    }

    var assignedRolesByID: [UUID: JamRole] {
        var result: [UUID: JamRole] = [:]
        if let bass { result[bass] = .bass }
        if let harmony { result[harmony] = .harmony }
        if let melody { result[melody] = .melody }
        return result
    }

    enum AddPhotoResult: Equatable {
        case added(JamSlotAssignments)
        case alreadyIncluded
        case full
        case unplayable
    }

    enum AddPhotosResult: Equatable {
        case added(JamSlotAssignments)
        case alreadyIncluded(count: Int)
        case full(availableSlots: Int)
        case unplayable(count: Int)
    }

    func hasDifferentActiveSlots(from other: JamSlotAssignments) -> Bool {
        bass != other.bass
            || harmony != other.harmony
            || melody != other.melody
    }

    func photoID(for role: JamRole) -> UUID? {
        switch role {
        case .bass: return bass
        case .harmony: return harmony
        case .melody: return melody
        }
    }

    func addingPhotoID(_ id: UUID, playable: Bool) -> AddPhotoResult {
        guard !allPhotoIDs.contains(id) else { return .alreadyIncluded }
        guard allPhotoIDs.count < Self.maximumPhotoCount else { return .full }
        guard playable else { return .unplayable }
        return .added(appendingAddedID(id, playableIDs: [id]))
    }

    func addingPhotoIDs(_ ids: [UUID], playableIDs: Set<UUID>) -> AddPhotosResult {
        let uniqueIDs = Self.orderedUnique(ids)
        let alreadyIncludedCount = uniqueIDs.filter { allPhotoIDs.contains($0) }.count
        guard alreadyIncludedCount == 0 else {
            return .alreadyIncluded(count: alreadyIncludedCount)
        }

        let unplayableCount = uniqueIDs.filter { !playableIDs.contains($0) }.count
        guard unplayableCount == 0 else {
            return .unplayable(count: unplayableCount)
        }

        let availableSlots = Self.maximumPhotoCount - allPhotoIDs.count
        guard uniqueIDs.count <= availableSlots else {
            return .full(availableSlots: max(availableSlots, 0))
        }

        var updated = self
        for id in uniqueIDs {
            guard case .added(let next) = updated.addingPhotoID(id, playable: true) else {
                return .full(availableSlots: max(Self.maximumPhotoCount - updated.allPhotoIDs.count, 0))
            }
            updated = next
        }
        return .added(updated)
    }

    func swapping(_ first: JamRole, _ second: JamRole) -> JamSlotAssignments {
        guard first != second else { return self }
        let firstID = photoID(for: first)
        let secondID = photoID(for: second)
        var next = self
        switch first {
        case .bass: next.bass = secondID
        case .harmony: next.harmony = secondID
        case .melody: next.melody = secondID
        }
        switch second {
        case .bass: next.bass = firstID
        case .harmony: next.harmony = firstID
        case .melody: next.melody = firstID
        }
        return next
    }

    func reconcilingSelection(
        selectedIDs: [UUID],
        playableIDs: Set<UUID>
    ) -> JamSlotAssignments {
        let orderedSelectedIDs = Self.orderedUnique(selectedIDs)
        let selectedIDSet = Set(orderedSelectedIDs)
        let currentAllIDSet = Set(allPhotoIDs)

        let survivingBass = bass.flatMap { id in
            selectedIDSet.contains(id) && playableIDs.contains(id) ? id : nil
        }
        let survivingHarmony = harmony.flatMap { id in
            selectedIDSet.contains(id) && playableIDs.contains(id) ? id : nil
        }
        let survivingMelody = melody.flatMap { id in
            selectedIDSet.contains(id) && playableIDs.contains(id) ? id : nil
        }

        var reserve = reserve.filter { selectedIDSet.contains($0) }
        reserve = Self.removingActiveDuplicates(
            from: Self.orderedUnique(reserve),
            activeIDs: [survivingBass, survivingHarmony, survivingMelody].compactMap { $0 }
        )

        let demotedActiveIDs = [bass, harmony, melody].compactMap { id -> UUID? in
            guard let id, selectedIDSet.contains(id) else { return nil }
            guard id != survivingBass, id != survivingHarmony, id != survivingMelody else { return nil }
            return id
        }
        reserve = Self.appendingUnique(reserve, ids: demotedActiveIDs)

        var reconciled = JamSlotAssignments(
            bass: survivingBass,
            harmony: survivingHarmony,
            melody: survivingMelody,
            reserve: reserve
        )
        reconciled = reconciled.canonicalized(playableIDs: playableIDs)

        let addedIDs = orderedSelectedIDs.filter { id in
            !currentAllIDSet.contains(id)
        }
        for addedID in addedIDs {
            reconciled = reconciled.appendingAddedID(addedID, playableIDs: playableIDs)
        }

        return reconciled.canonicalized(playableIDs: playableIDs)
    }

    func pruningInvalidIDs(
        validIDs: Set<UUID>,
        playableIDs: Set<UUID>
    ) -> JamSlotAssignments {
        let filteredSelectedIDs = allPhotoIDs.filter { validIDs.contains($0) }

        let pruned = JamSlotAssignments(
            bass: bass.flatMap { validIDs.contains($0) ? $0 : nil },
            harmony: harmony.flatMap { validIDs.contains($0) ? $0 : nil },
            melody: melody.flatMap { validIDs.contains($0) ? $0 : nil },
            reserve: reserve.filter { validIDs.contains($0) }
        )

        return pruned.reconcilingSelection(
            selectedIDs: filteredSelectedIDs,
            playableIDs: playableIDs
        )
    }

    private func appendingAddedID(
        _ id: UUID,
        playableIDs: Set<UUID>
    ) -> JamSlotAssignments {
        guard !allPhotoIDs.contains(id) else { return self }

        var next = self

        if playableIDs.contains(id) {
            switch activePhotoIDs.count {
            case 0:
                next.melody = id
            case 1 where next.bass == nil && next.harmony == nil && next.melody != nil:
                next.bass = id
            case 2 where next.bass != nil && next.harmony == nil && next.melody != nil:
                next.harmony = id
            default:
                next.reserve.append(id)
            }
        } else {
            next.reserve.append(id)
        }

        return next.canonicalized(playableIDs: playableIDs)
    }

    private func canonicalized(playableIDs: Set<UUID>) -> JamSlotAssignments {
        var demotedToReserve: [UUID] = []
        var seenActiveIDs: Set<UUID> = []

        func sanitizeActiveID(_ id: UUID?) -> UUID? {
            guard let id else { return nil }
            guard playableIDs.contains(id), !seenActiveIDs.contains(id) else {
                demotedToReserve.append(id)
                return nil
            }

            seenActiveIDs.insert(id)
            return id
        }

        var bass = sanitizeActiveID(bass)
        var harmony = sanitizeActiveID(harmony)
        var melody = sanitizeActiveID(melody)

        var reserve = Self.orderedUnique(reserve)
        reserve = Self.removingActiveDuplicates(
            from: reserve,
            activeIDs: [bass, harmony, melody].compactMap { $0 }
        )
        reserve = Self.appendingUnique(reserve, ids: demotedToReserve)
        reserve = Self.removingActiveDuplicates(
            from: reserve,
            activeIDs: [bass, harmony, melody].compactMap { $0 }
        )

        if bass == nil, let promoted = Self.removeFirstPlayableID(from: &reserve, playableIDs: playableIDs) {
            bass = promoted
        }
        if harmony == nil, let promoted = Self.removeFirstPlayableID(from: &reserve, playableIDs: playableIDs) {
            harmony = promoted
        }
        if melody == nil, let promoted = Self.removeFirstPlayableID(from: &reserve, playableIDs: playableIDs) {
            melody = promoted
        }

        let activeIDs = [bass, harmony, melody].compactMap { $0 }

        switch activeIDs.count {
        case 0:
            bass = nil
            harmony = nil
            melody = nil
        case 1:
            melody = bass ?? harmony ?? melody
            bass = nil
            harmony = nil
        case 2:
            if bass != nil, melody != nil {
                harmony = nil
            } else if bass != nil, harmony != nil {
                melody = harmony
                harmony = nil
            } else if harmony != nil, melody != nil {
                bass = harmony
                harmony = nil
            }
        default:
            break
        }

        reserve = Self.removingActiveDuplicates(
            from: Self.orderedUnique(reserve),
            activeIDs: [bass, harmony, melody].compactMap { $0 }
        )

        return JamSlotAssignments(
            bass: bass,
            harmony: harmony,
            melody: melody,
            reserve: reserve
        )
    }

    private static func removeFirstPlayableID(
        from reserve: inout [UUID],
        playableIDs: Set<UUID>
    ) -> UUID? {
        guard let index = reserve.firstIndex(where: { playableIDs.contains($0) }) else {
            return nil
        }

        return reserve.remove(at: index)
    }

    private static func orderedUnique(_ ids: [UUID]) -> [UUID] {
        var result: [UUID] = []

        for id in ids where !result.contains(id) {
            result.append(id)
        }

        return result
    }

    private static func appendingUnique(_ existing: [UUID], ids: [UUID]) -> [UUID] {
        var result = existing
        for id in ids where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    private static func removingActiveDuplicates(
        from reserve: [UUID],
        activeIDs: [UUID]
    ) -> [UUID] {
        reserve.filter { id in
            !activeIDs.contains(id)
        }
    }
}
