import SwiftUI

struct JamLibraryView: View {
    let library: PhotoLibraryViewModel
    let isActive: Bool

    @State private var state = JamLibraryState()
    @State private var pendingDelete: PersistedJam?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        Group {
            if let selectedJam = state.selectedJam {
                JamView(
                    library: library,
                    isActive: isActive,
                    initialJam: selectedJam,
                    onClose: {
                        Task { await state.closeSession() }
                    }
                )
                .id(selectedJam.id)
            } else {
                libraryContent
            }
        }
        .task {
            await state.loadIfNeeded()
        }
        .alert("Delete Jam?", isPresented: deleteConfirmationPresented) {
            Button("Delete", role: .destructive) {
                guard let jam = pendingDelete else { return }
                Task {
                    await state.deleteJam(jam)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This removes the Jam from this device. Photos and covers are not deleted.")
        }
        .alert("Jam Error", isPresented: errorPresented) {
            Button("OK") {
                state.errorMessage = nil
            }
        } message: {
            Text(state.errorMessage ?? "Something went wrong.")
        }
    }

    private var libraryContent: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemBackground)

            VStack(spacing: 18) {
                searchField

                contentBody
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 92)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            createButton
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch state.loadState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView("Could not load Jams", systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if state.jams.isEmpty && state.draftJam == nil {
                Spacer(minLength: 0)
            } else if state.filteredJams.isEmpty && state.draftJam == nil {
                ContentUnavailableView("No Jams Found", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        if let draft = state.draftJam {
                            JamCard(
                                id: draft.id,
                                name: draft.name,
                                coverData: nil,
                                isEditing: state.editingJamID == draft.id,
                                editingName: $state.editingName,
                                onOpen: {},
                                onRename: {},
                                onDelete: { state.cancelDraftCreation() },
                                onConfirmEdit: {
                                    Task { await state.confirmDraftCreation() }
                                },
                                onCancelEdit: {
                                    state.cancelDraftCreation()
                                }
                            )
                        }

                        ForEach(state.filteredJams) { jam in
                            JamCard(
                                id: jam.id,
                                name: jam.name,
                                coverData: coverData(for: jam),
                                isEditing: state.editingJamID == jam.id,
                                editingName: $state.editingName,
                                onOpen: {
                                    Task { await state.openJam(jam) }
                                },
                                onRename: {
                                    state.beginRename(jam)
                                },
                                onDelete: {
                                    pendingDelete = jam
                                },
                                onConfirmEdit: {
                                    Task { await state.confirmRename(jam) }
                                },
                                onCancelEdit: {
                                    state.cancelRename()
                                }
                            )
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $state.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var createButton: some View {
        Button {
            state.beginDraftCreation()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("Create a Jam")
                    .font(.headline)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var deleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )
    }

    private func coverData(for jam: PersistedJam) -> Data? {
        let ids = jam.slotAssignments.activePhotoIDs + jam.slotAssignments.reserve
        guard let id = ids.first(where: { candidate in
            library.items.contains { $0.id == candidate }
        }) else {
            return nil
        }
        return library.coverDataByID[id]
    }
}
