import Foundation

// MARK: - PhotoStore

/// Handles persistence to Application Support/Dap/.
///
/// Declared as an `actor` so that every method executes on the actor's
/// serial executor — guaranteeing that concurrent calls to `save` and
/// `updateMetadata` are never interleaved. The read → modify → write
/// sequence inside `updateMetadata` contains no `await`, so it runs
/// atomically within a single actor turn.
actor PhotoStore {

    // MARK: Shared instance

    static let shared = PhotoStore()

    // MARK: - Directories & URLs

    private func libraryDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Dap", isDirectory: true)
    }

    private func coversDirectory() throws -> URL {
        try libraryDirectory().appendingPathComponent("Covers", isDirectory: true)
    }

    private func libraryURL() throws -> URL {
        try libraryDirectory().appendingPathComponent("library.json")
    }

    // MARK: - Load

    /// Reads and decodes library.json. Returns empty array if file does not exist.
    func load() throws -> [PhotoSound] {
        let url = try libraryURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PhotoSound].self, from: data)
    }

    // MARK: - Save

    /// Persists a new ProcessedPhotoSound alongside the existing library.
    ///
    /// Flow:
    /// 1. Create directories.
    /// 2. Write cover PNG.
    /// 3. Encode new library array atomically.
    /// 4. Remove cover if JSON write fails.
    /// 5. Return updated array only on full success.
    func save(_ result: ProcessedPhotoSound,
              existing: [PhotoSound]) throws -> [PhotoSound] {
        let libDir    = try libraryDirectory()
        let coversDir = try coversDirectory()
        let libURL    = try libraryURL()
        let coverURL  = coversDir.appendingPathComponent(result.sound.coverFilename)

        let fm = FileManager.default
        try fm.createDirectory(at: libDir,    withIntermediateDirectories: true)
        try fm.createDirectory(at: coversDir, withIntermediateDirectories: true)

        // Write cover PNG first.
        try result.coverData.write(to: coverURL)

        // Prepend new item and sort newest-first.
        let updated = ([result.sound] + existing)
            .sorted { $0.createdAt > $1.createdAt }

        do {
            let jsonData = try JSONEncoder().encode(updated)
            try jsonData.write(to: libURL, options: .atomic)
        } catch {
            // JSON write failed — remove the cover to avoid orphaned files.
            try? fm.removeItem(at: coverURL)
            throw error
        }

        return updated
    }

    // MARK: - Metadata update

    /// Updates only `name` and `description` for the item matching `id`.
    /// All other properties (sequence, coverFilename, createdAt, …) are preserved.
    ///
    /// The entire read → modify → write sequence is synchronous (no `await`)
    /// and executes in a single actor turn, so it cannot be interleaved with
    /// a concurrent `save` or another `updateMetadata` call.
    @discardableResult
    func updateMetadata(
        id: UUID,
        name: String,
        description: String
    ) throws -> PhotoSound {
        let libURL = try libraryURL()

        // Synchronous read — no await, no suspension point.
        var library: [PhotoSound]
        if FileManager.default.fileExists(atPath: libURL.path) {
            let data = try Data(contentsOf: libURL)
            library = try JSONDecoder().decode([PhotoSound].self, from: data)
        } else {
            library = []
        }

        guard let index = library.firstIndex(where: { $0.id == id }) else {
            throw UpdateMetadataError.notFound
        }

        var updated = library[index]
        updated.name        = name
        updated.description = description
        library[index]      = updated

        // Synchronous atomic write — completes before the actor releases the turn.
        let jsonData = try JSONEncoder().encode(library)
        try jsonData.write(to: libURL, options: .atomic)

        return updated
    }

    enum UpdateMetadataError: Error { case notFound }

    func delete(id: UUID) throws -> [PhotoSound] {
        let libURL = try libraryURL()
        let fm = FileManager.default

        guard fm.fileExists(atPath: libURL.path) else {
            throw DeleteError.notFound
        }

        let data = try Data(contentsOf: libURL)
        var library = try JSONDecoder().decode([PhotoSound].self, from: data)

        guard let index = library.firstIndex(where: { $0.id == id }) else {
            throw DeleteError.notFound
        }

        let removed = library.remove(at: index)
        let coverURL = try coversDirectory().appendingPathComponent(removed.coverFilename)
        let stashedCoverURL = coverURL.appendingPathExtension("deleting")
        let hadCover = fm.fileExists(atPath: coverURL.path)

        if hadCover {
            try? fm.removeItem(at: stashedCoverURL)
            try fm.moveItem(at: coverURL, to: stashedCoverURL)
        }

        do {
            let jsonData = try JSONEncoder().encode(library)
            try jsonData.write(to: libURL, options: .atomic)
        } catch {
            if hadCover, fm.fileExists(atPath: stashedCoverURL.path) {
                try? fm.moveItem(at: stashedCoverURL, to: coverURL)
            }
            throw error
        }

        if hadCover {
            try? fm.removeItem(at: stashedCoverURL)
        }

        return library
    }

    enum DeleteError: Error { case notFound }

    // MARK: - Cover data cache

    /// Loads cover PNG data for an array of sounds into a dictionary keyed by UUID.
    /// Missing files are silently skipped.
    func coverData(for sounds: [PhotoSound]) throws -> [UUID: Data] {
        let coversDir = try coversDirectory()
        var result: [UUID: Data] = [:]
        for sound in sounds {
            let url = coversDir.appendingPathComponent(sound.coverFilename)
            if let data = try? Data(contentsOf: url) {
                result[sound.id] = data
            }
        }
        return result
    }
}
