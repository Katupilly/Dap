import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class JamLibraryState {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var loadState: LoadState = .idle
    var jams: [PersistedJam] = []
    var searchText = ""
    var selectedJam: PersistedJam?
    var errorMessage: String?
    var draftJam: DraftJam?
    var editingJamID: UUID?
    var editingName = ""

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dap", category: "JamLibrary")

    var filteredJams: [PersistedJam] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return jams }

        return jams.filter { jam in
            jam.name.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    var hasLoaded: Bool {
        if case .loaded = loadState { return true }
        return false
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        loadState = .loading
        do {
            jams = try await JamStore.shared.list()
            loadState = .loaded
        } catch {
            let message = "Could not load Jams."
            errorMessage = message
            loadState = .failed(message)
            logger.error("Failed to list Jams: \(error.localizedDescription, privacy: .public)")
        }
    }

    func createJam(named name: String) async {
        let normalizedName = PersistedJam.normalizedName(name)
        do {
            let jam = try await JamStore.shared.create(named: normalizedName)
            draftJam = nil
            jams.insert(jam, at: 0)
            selectedJam = jam
            loadState = .loaded
        } catch {
            errorMessage = "Could not create Jam."
            logger.error("Failed to create Jam: \(error.localizedDescription, privacy: .public)")
        }
    }

    func beginDraftCreation() {
        guard draftJam == nil else { return }
        let draft = DraftJam(name: PersistedJam.defaultName)
        draftJam = draft
        editingJamID = draft.id
        editingName = draft.name
        loadState = .loaded
    }

    func cancelDraftCreation() {
        let draftID = draftJam?.id
        draftJam = nil
        if editingJamID == draftID {
            editingJamID = nil
            editingName = ""
        }
    }

    func confirmDraftCreation() async {
        guard draftJam != nil else { return }
        await createJam(named: editingName)
        editingJamID = nil
        editingName = ""
    }

    func openJam(_ jam: PersistedJam) async {
        do {
            let loaded = try await JamStore.shared.load(id: jam.id)
            replaceInList(with: loaded)
            selectedJam = loaded
        } catch {
            errorMessage = "Could not open Jam."
            logger.error("Failed to open Jam \(jam.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func renameJam(_ jam: PersistedJam, to name: String) async {
        do {
            let renamed = try await JamStore.shared.rename(id: jam.id, name: name)
            replaceInList(with: renamed)
            if selectedJam?.id == renamed.id {
                selectedJam = renamed
            }
            editingJamID = nil
            editingName = ""
        } catch {
            errorMessage = "Could not rename Jam."
            logger.error("Failed to rename Jam \(jam.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func beginRename(_ jam: PersistedJam) {
        editingJamID = jam.id
        editingName = jam.name
    }

    func cancelRename() {
        editingJamID = nil
        editingName = ""
    }

    func confirmRename(_ jam: PersistedJam) async {
        await renameJam(jam, to: editingName)
    }

    func deleteJam(_ jam: PersistedJam) async {
        do {
            try await JamStore.shared.delete(id: jam.id)
            jams.removeAll { $0.id == jam.id }
            if selectedJam?.id == jam.id {
                selectedJam = nil
            }
            loadState = .loaded
        } catch {
            errorMessage = "Could not delete Jam."
            logger.error("Failed to delete Jam \(jam.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func closeSession() async {
        selectedJam = nil
        await reload()
    }

    private func replaceInList(with jam: PersistedJam) {
        if let index = jams.firstIndex(where: { $0.id == jam.id }) {
            jams[index] = jam
        } else {
            jams.insert(jam, at: 0)
        }
        jams.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct DraftJam: Identifiable, Equatable {
    let id = UUID()
    var name: String
}
