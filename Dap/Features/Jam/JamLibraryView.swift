import SwiftUI

struct JamLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let library: PhotoLibraryViewModel
    let isActive: Bool

    @State private var state = JamLibraryState()
    @State private var pendingDelete: PersistedJam?
    @FocusState private var isSearchFocused: Bool

    private let horizontalPadding: CGFloat = 20
    private let searchHeight: CGFloat = 46
    private let topBlurHeight: CGFloat = 120
    private let topContentInset: CGFloat = 84
    private let bottomBlurHeight: CGFloat = 88
    private let gridSpacing: CGFloat = 18

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ZStack {
            if let selectedJam = state.selectedJam {
                JamView(
                    library: library,
                    isActive: isActive,
                    initialJam: selectedJam,
                    initialCoverData: coverData(for: selectedJam),
                    onClose: {
                        await state.closeSession()
                    }
                )
                .id(selectedJam.id)
                .transition(sessionTransition)
            } else {
                libraryContent
                    .transition(sessionTransition)
            }
        }
        .animation(sessionAnimation, value: state.selectedJam?.id)
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

            contentBody

            topBlurLayer
                .frame(maxHeight: .infinity, alignment: .top)

            searchField
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .frame(maxHeight: .infinity, alignment: .top)

            if shouldShowCreateChrome {
                bottomBlurLayer
                    .frame(maxHeight: .infinity, alignment: .bottom)

                createButton
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: shouldShowCreateChrome)
    }

    @ViewBuilder
    private var contentBody: some View {
        switch state.loadState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismissSearch)
        case .failed:
            ContentUnavailableView("Could not load Jams", systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismissSearch)
        case .loaded:
            if state.jams.isEmpty && state.draftJam == nil {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissSearch)
            } else if state.filteredJams.isEmpty && state.draftJam == nil {
                ContentUnavailableView("No Jams Found", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissSearch)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        if let draft = state.draftJam {
                            JamCard(
                                id: draft.id,
                                name: draft.name,
                                coverData: nil,
                                isEditing: state.editingJamID == draft.id,
                                editingName: $state.editingName,
                                onOpen: {},
                                onRename: {},
                                onDelete: {
                                    dismissSearch()
                                    state.cancelDraftCreation()
                                },
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
                                    dismissSearch()
                                    Task { await state.openJam(jam) }
                                },
                                onRename: {
                                    dismissSearch()
                                    state.beginRename(jam)
                                },
                                onDelete: {
                                    dismissSearch()
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
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, topContentInset)
                    .padding(.bottom, shouldShowCreateChrome ? 120 : 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
            }
        }
    }

    private var topBlurLayer: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)

            Color.black.opacity(0.16)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.82), location: 0.38),
                    .init(color: .black.opacity(0.28), location: 0.76),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: topBlurHeight)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private var bottomBlurLayer: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Rectangle()
                    .fill(.regularMaterial)

                Color.black.opacity(0.18)
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.30),
                        .init(color: .black.opacity(0.40), location: 0.60),
                        .init(color: .black.opacity(0.88), location: 0.86),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: bottomBlurHeight)
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search", text: $state.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: searchHeight)
        .background(.ultraThinMaterial.opacity(0.92), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var createButton: some View {
        Button {
            dismissSearch()
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

    private var shouldShowCreateChrome: Bool {
        !isSearchFocused && state.editingJamID == nil
    }

    private var sessionAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.18)
            : .easeInOut(duration: 0.28)
    }

    private var sessionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }

    private func dismissSearch() {
        guard isSearchFocused else { return }
        isSearchFocused = false
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
