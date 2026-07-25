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

        refiningMetadataIDs.insert(soundID)

        let context = MusicalContext(sound: sound)

        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }

            // Run Vision + Foundation Models off-main; result is Sendable.
            let generated = await PhotoMetadataGenerator.generate(
                imageData: imageData,
                musicalContext: context
            )

            guard !Task.isCancelled else { return }

            guard let self else { return }

            if let metadata = generated {
                // Persist — errors are silent; fallback stays in place.
                if let updatedSound = try? await PhotoStore.shared.updateMetadata(
                    id: soundID,
                    name: metadata.name,
                    description: metadata.description
                ) {
                    // Patch only the matching item in memory.
                    if let idx = self.items.firstIndex(where: { $0.id == soundID }) {
                        self.items[idx] = updatedSound
                    }
                }
            }

            self.refiningMetadataIDs.remove(soundID)
            self.metadataTasks.removeValue(forKey: soundID)
        }

        metadataTasks[soundID] = task
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

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case loadFailed
        var errorDescription: String? { "Could not load the selected image." }
    }
}
