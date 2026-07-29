import Foundation
import OSLog

actor JamStore {
    static let shared = JamStore()

    enum StoreError: Error, Equatable {
        case notFound
        case corruptedFile(UUID)
        case unsupportedSchemaVersion(Int)
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dap", category: "JamStore")

    func list() throws -> [PersistedJam] {
        let directory = try jamsDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "json" }

        var jams: [PersistedJam] = []
        for url in urls {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                logger.error("Ignoring Jam file with invalid filename: \(url.lastPathComponent, privacy: .public)")
                continue
            }

            do {
                var jam = try decodeJam(at: url, fallbackID: id)
                jam = sanitizedForStorage(jam, updatingTimestamp: false)
                jams.append(jam)
            } catch StoreError.corruptedFile(let id) {
                logger.error("Ignoring corrupted Jam file: \(id.uuidString, privacy: .public)")
            } catch StoreError.unsupportedSchemaVersion(let version) {
                logger.error("Ignoring Jam file with unsupported schema version: \(version, privacy: .public)")
            }
        }

        return jams.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func create(named name: String = "Untitled Jam") throws -> PersistedJam {
        let now = Date()
        let jam = PersistedJam(
            schemaVersion: PersistedJam.currentSchemaVersion,
            id: UUID(),
            name: PersistedJam.normalizedName(name),
            createdAt: now,
            updatedAt: now,
            slotAssignments: PersistedJamSlotAssignments(
                bass: nil,
                harmony: nil,
                melody: nil,
                reserve: []
            ),
            vibePosition: PersistedPoint(x: 0.5, y: 0.5),
            drumKitSelection: "auto",
            effectSettings: PersistedJamEffectSettings(
                reverbEnabled: false,
                reverbMix: 0.28,
                delayEnabled: false,
                delayMix: 0.22,
                lfoEnabled: false,
                lfoAmount: 0.35
            ),
            melodyVariation: .initial
        )

        try write(jam)
        return jam
    }

    func load(id: UUID) throws -> PersistedJam {
        let url = try jamURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound
        }

        return try decodeJam(at: url, fallbackID: id)
    }

    func save(_ jam: PersistedJam) throws -> PersistedJam {
        try validateSchemaVersion(jam.schemaVersion)
        let sanitized = sanitizedForStorage(jam, updatingTimestamp: true)
        try write(sanitized)
        return sanitized
    }

    func rename(id: UUID, name: String) throws -> PersistedJam {
        var jam = try load(id: id)
        jam.name = name
        return try save(jam)
    }

    func delete(id: UUID) throws {
        let url = try jamURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound
        }

        try FileManager.default.removeItem(at: url)
    }

    private func libraryDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Dap", isDirectory: true)
    }

    private func jamsDirectory() throws -> URL {
        try libraryDirectory().appendingPathComponent("Jams", isDirectory: true)
    }

    private func jamURL(for id: UUID) throws -> URL {
        try jamsDirectory().appendingPathComponent("\(id.uuidString).json")
    }

    private func decodeJam(at url: URL, fallbackID: UUID) throws -> PersistedJam {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.corruptedFile(fallbackID)
        }

        let jam: PersistedJam
        do {
            jam = try Self.decoder.decode(PersistedJam.self, from: data)
        } catch {
            throw StoreError.corruptedFile(fallbackID)
        }

        try validateSchemaVersion(jam.schemaVersion)
        return jam
    }

    private func write(_ jam: PersistedJam) throws {
        try validateSchemaVersion(jam.schemaVersion)

        let directory = try jamsDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let data = try Self.encoder.encode(jam)
        try data.write(to: try jamURL(for: jam.id), options: .atomic)
    }

    private func validateSchemaVersion(_ version: Int) throws {
        guard version == PersistedJam.currentSchemaVersion else {
            throw StoreError.unsupportedSchemaVersion(version)
        }
    }

    private func sanitizedForStorage(
        _ jam: PersistedJam,
        updatingTimestamp: Bool
    ) -> PersistedJam {
        var sanitized = jam
        sanitized.name = PersistedJam.normalizedName(jam.name)
        sanitized.slotAssignments = Self.sanitizedAssignments(jam.slotAssignments)
        if updatingTimestamp {
            sanitized.updatedAt = Date()
        }
        return sanitized
    }

    private static func sanitizedAssignments(
        _ assignments: PersistedJamSlotAssignments
    ) -> PersistedJamSlotAssignments {
        var seen: Set<UUID> = []

        func uniqueActiveID(_ id: UUID?) -> UUID? {
            guard let id, !seen.contains(id) else { return nil }
            seen.insert(id)
            return id
        }

        let bass = uniqueActiveID(assignments.bass)
        let harmony = uniqueActiveID(assignments.harmony)
        let melody = uniqueActiveID(assignments.melody)

        var reserve: [UUID] = []
        for id in assignments.reserve where !seen.contains(id) {
            seen.insert(id)
            reserve.append(id)
        }

        return PersistedJamSlotAssignments(
            bass: bass,
            harmony: harmony,
            melody: melody,
            reserve: reserve
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
