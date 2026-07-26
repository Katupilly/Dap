import Foundation
import PhotosUI
import SwiftUI

// MARK: - PhotoLibraryViewModel

/// Single shared ViewModel for Gallery and Capture.
/// Owns the library items, cover data cache, import state, playback,
/// and the progressive metadata-refinement tasks.
@MainActor
@Observable
final class PhotoLibraryViewModel {

    // MARK: Persisted state

    private(set) var items: [PhotoSound] = []

    // MARK: Cover cache (UUID → PNG Data already in memory)
    // Views must NOT call Data(contentsOf:) in their body.

    private(set) var coverDataByID: [UUID: Data] = [:]

    // MARK: Import state

    private(set) var isImporting = false
    private(set) var batchCompletedCount = 0
    private(set) var batchTotalCount = 0

    // MARK: Progressive metadata refinement

    /// IDs whose metadata is currently being generated in the background.
    private(set) var refiningMetadataIDs: Set<UUID> = []

    /// Live metadata tasks keyed by PhotoSound ID.
    private var metadataTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Playback state

    /// UUID of the currently-playing sound, nil if nothing is playing.
    private(set) var playingID: UUID?

    // MARK: Private

    private let player = MusicPlayer()
    private var hasLoaded = false

    // MARK: Init

    init() {
        player.onPlaybackFinished = { [weak self] in
            self?.playingID = nil
        }
    }

    // MARK: - Library loading

    /// Loads library from disk once. Subsequent calls are no-ops.
    func loadLibrary() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            let loaded = try await PhotoStore.shared.load()
            let covers = try await PhotoStore.shared.coverData(for: loaded)
            items         = loaded
            coverDataByID = covers
        } catch {
            // Library may not exist yet on first launch.
            items = []
        }
    }

    // MARK: - Import

    func importPhoto(from pickerItem: PhotosPickerItem) async throws {
        guard let imageData = try await pickerItem.loadTransferable(type: Data.self) else {
            throw ImportError.loadFailed
        }
        try await importPhotoData(imageData)
    }

    func importPhotos(
        from pickerItems: [PhotosPickerItem]
    ) async -> (importedCount: Int, failedCount: Int) {
        guard !isImporting else {
            return (0, pickerItems.count)
        }

        isImporting = true
        batchTotalCount = pickerItems.count
        batchCompletedCount = 0

        defer {
            isImporting = false
        }

        var workingItems = items
        var workingCoverData = coverDataByID
        var successfulImports: [(soundID: UUID, pickerItem: PhotosPickerItem)] = []
        var importedCount = 0
        var failedCount = 0

        for pickerItem in pickerItems {
            do {
                try Task.checkCancellation()

                guard let imageData = try await pickerItem.loadTransferable(type: Data.self) else {
                    failedCount += 1
                    batchCompletedCount += 1
                    continue
                }

                let result = try await PhotoMusicPipeline.process(imageData: imageData)
                workingItems = try await PhotoStore.shared.save(result, existing: workingItems)
                workingCoverData[result.sound.id] = result.coverData
                successfulImports.append((result.sound.id, pickerItem))
                importedCount += 1
                batchCompletedCount += 1
            } catch is CancellationError {
                break
            } catch {
                failedCount += 1
                batchCompletedCount += 1
            }
        }

        if importedCount > 0 {
            items = workingItems
            coverDataByID = workingCoverData
            scheduleBatchMetadataRefinement(for: successfulImports)
        }

        return (importedCount, failedCount)
    }

    /// Processes imageData, saves the essential result, and starts background metadata refinement.
    @discardableResult
    func importPhotoData(_ imageData: Data) async throws -> Bool {
        guard !isImporting else { return false }
        isImporting = true
        defer { isImporting = false }

        let result  = try await PhotoMusicPipeline.process(imageData: imageData)
        let updated = try await PhotoStore.shared.save(result, existing: items)

        // Update memory only after full disk success.
        coverDataByID[result.sound.id] = result.coverData
        items = updated

        // Kick off background metadata generation (non-throwing, non-blocking).
        scheduleMetadataRefinement(for: result.sound, imageData: imageData)
        return true
    }

    // MARK: - Progressive metadata

    private func scheduleMetadataRefinement(for sound: PhotoSound, imageData: Data) {
        let soundID = sound.id

        // Cancel any in-flight generation for this ID before starting a new one.
        metadataTasks[soundID]?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.refineMetadata(for: soundID, imageData: imageData)
        }

        metadataTasks[soundID] = task
    }

    private func scheduleBatchMetadataRefinement(
        for successfulImports: [(soundID: UUID, pickerItem: PhotosPickerItem)]
    ) {
        Task { [weak self] in
            guard let self else { return }

            for successfulImport in successfulImports {
                guard !Task.isCancelled else { break }

                guard let imageData = try? await successfulImport.pickerItem.loadTransferable(type: Data.self) else {
                    continue
                }

                await self.refineMetadata(for: successfulImport.soundID, imageData: imageData)
            }
        }
    }

    private func refineMetadata(for soundID: UUID, imageData: Data) async {
        guard let sound = items.first(where: { $0.id == soundID }) else { return }

        refiningMetadataIDs.insert(soundID)
        let context = MusicalContext(sound: sound)

        defer {
            refiningMetadataIDs.remove(soundID)
            metadataTasks.removeValue(forKey: soundID)
        }

        guard !Task.isCancelled else { return }

        // Run Vision + Foundation Models off-main; result is Sendable.
        let generated = await PhotoMetadataGenerator.generate(
            imageData: imageData,
            musicalContext: context
        )

        guard !Task.isCancelled else { return }

        if let metadata = generated {
            // Persist — errors are silent; fallback stays in place.
            if let updatedSound = try? await PhotoStore.shared.updateMetadata(
                id: soundID,
                name: metadata.name,
                description: metadata.description
            ) {
                // Patch only the matching item in memory.
                if let idx = items.firstIndex(where: { $0.id == soundID }) {
                    items[idx] = updatedSound
                }
            }
        }
    }

    // MARK: - Playback

    /// Toggles playback for a sound:
    /// - Tapping the playing sound → stop.
    /// - Tapping a different sound → stop current, play new.
    func toggle(sound: PhotoSound) {
        if playingID == sound.id {
            player.stop()
            playingID = nil
        } else {
            player.stop()
            player.play(sequence: sound.sequence)
            playingID = sound.id
        }
    }

    /// Stops any active playback.
    func stopPlayback() {
        player.stop()
        playingID = nil
    }

    func playTransientSequence(_ sequence: MusicSequence, loops: Bool = false) {
        stopPlayback()
        player.play(sequence: sequence, loops: loops)
    }

    func stopTransientPlayback() {
        stopPlayback()
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case loadFailed
        var errorDescription: String? { "Could not load the selected image." }
    }
}
