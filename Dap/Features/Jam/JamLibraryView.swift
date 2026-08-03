import SwiftUI

struct JamLibraryView: View {
    let library: PhotoLibraryViewModel
    let isActive: Bool
    let createJamTrigger: UUID?
    let onSessionPresentationChange: (Bool) -> Void

    @State private var state = JamLibraryState()
    @State private var pendingDelete: PersistedJam?
    @State private var lastHandledCreateJamTrigger: UUID?
    @FocusState private var isSearchFocused: Bool

    private let horizontalPadding: CGFloat = 20
    private let segmentedControlTopInset: CGFloat = 8
    private let segmentedControlHeight: CGFloat = 38
    private let segmentToSearchSpacing: CGFloat = 22
    private let searchHeight: CGFloat = 46
    private let gridTopSpacing: CGFloat = 20
    private let gridSpacing: CGFloat = 18

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    private var searchTopInset: CGFloat {
        segmentedControlTopInset + segmentedControlHeight + segmentToSearchSpacing
    }

    private var topContentInset: CGFloat {
        searchTopInset + searchHeight + gridTopSpacing
    }

    var body: some View {
        NavigationStack {
            libraryContent
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $state.selectedJam) { selectedJam in
                    JamView(
                        library: library,
                        isActive: isActive,
                        initialJam: selectedJam,
                        initialCoverDescriptor: coverDescriptor(for: selectedJam),
                        onClose: {
                            await state.closeSession()
                        }
                    )
                    .id(selectedJam.id)
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationBarBackButtonHidden(true)
                }
        }
        .onChange(of: state.selectedJam?.id) { oldValue, newValue in
            dismissSearch()
            onSessionPresentationChange(newValue != nil)
            // Covers the interactive swipe-back gesture, which clears
            // `selectedJam` directly through the binding without going
            // through `closeSession()`.
            guard oldValue != nil, newValue == nil else { return }
            Task { await state.reload() }
        }
        .onChange(of: isActive) { _, isActive in
            guard !isActive else { return }
            dismissSearch()
        }
        .onAppear {
            onSessionPresentationChange(state.selectedJam != nil)
            handleCreateJamTrigger(createJamTrigger)
        }
        .onDisappear {
            dismissSearch()
            onSessionPresentationChange(false)
        }
        .onChange(of: createJamTrigger) { _, newValue in
            handleCreateJamTrigger(newValue)
        }
        .task(id: isActive) {
            guard isActive else { return }

            if state.hasLoaded {
                await state.reload()
            } else {
                await state.loadIfNeeded()
            }
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

            edgeBlurOverlays

            searchField
                .padding(.horizontal, horizontalPadding)
                .padding(.top, searchTopInset)
                .frame(maxHeight: .infinity, alignment: .top)

            if shouldShowCreateChrome {
                createButton
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: shouldShowCreateChrome)
    }

    private var edgeBlurOverlays: some View {
        Group {
            if isActive && state.selectedJam == nil {
                DapEdgeBlur(edge: .top)
                    .frame(maxWidth: .infinity)
                    .frame(height: DapEdgeBlur.topHeight)
                    .offset(y: -DapEdgeBlur.edgeExtension)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)

                DapEdgeBlur(edge: .bottom)
                    .frame(maxWidth: .infinity)
                    .frame(height: DapEdgeBlur.bottomHeight)
                    .offset(y: DapEdgeBlur.edgeExtension)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
        }
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
                                coverDescriptor: .empty(jamID: draft.id),
                                detailText: nil,
                                status: nil,
                                isEditing: state.editingJamID == draft.id,
                                editingPlaceholder: PersistedJam.defaultName,
                                editingName: $state.editingName,
                                showsActions: false,
                                showsConfirmAction: false,
                                isOpenDisabled: true,
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
                                coverDescriptor: coverDescriptor(for: jam),
                                detailText: nil,
                                status: nil,
                                isEditing: state.editingJamID == jam.id,
                                editingPlaceholder: "Jam name",
                                editingName: $state.editingName,
                                showsActions: true,
                                showsConfirmAction: true,
                                isOpenDisabled: false,
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
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissSearch)
                }
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
                .focused($isSearchFocused)

            if !state.searchText.isEmpty {
                Button {
                    state.searchText = ""
                    dismissSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
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

    private func dismissSearch() {
        guard isSearchFocused else { return }
        isSearchFocused = false
    }

    private func handleCreateJamTrigger(_ trigger: UUID?) {
        guard let trigger, trigger != lastHandledCreateJamTrigger else { return }
        lastHandledCreateJamTrigger = trigger

        Task { @MainActor in
            dismissSearch()
            await state.loadIfNeeded()
            await state.presentNewJamFlow()
        }
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

    private func coverDescriptor(for jam: PersistedJam) -> JamCoverDescriptor {
        JamCoverDescriptor(jam: jam, sounds: library.items)
    }
}
