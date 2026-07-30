import SwiftUI
import UIKit

struct JamPhotoSelectorSheet: View {
    let sounds: [PhotoSound]
    let coverDataByID: [UUID: Data]
    @Binding var isPresented: Bool
    let onConfirmSelection: ([UUID]) -> Void

    @State private var pendingSelectionIDs: Set<UUID> = []

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var selectionSummary: String {
        switch pendingSelectionIDs.count {
        case 0:
            return "Select up to 3 photos"
        case 1:
            return "1 of 3 selected"
        case 2:
            return "2 of 3 selected"
        default:
            return "3 of 3 selected"
        }
    }

    init(
        sounds: [PhotoSound],
        coverDataByID: [UUID: Data],
        selectedPhotoIDs: [UUID],
        isPresented: Binding<Bool>,
        onConfirmSelection: @escaping ([UUID]) -> Void
    ) {
        self.sounds = sounds
        self.coverDataByID = coverDataByID
        self._isPresented = isPresented
        self.onConfirmSelection = onConfirmSelection
        _pendingSelectionIDs = State(initialValue: Set(selectedPhotoIDs))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(selectionSummary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sounds) { sound in
                            let isSelected = pendingSelectionIDs.contains(sound.id)
                            let canSelectMore = pendingSelectionIDs.count < 3 || isSelected

                            Button {
                                toggleSelection(for: sound.id)
                            } label: {
                                JamPhotoCell(
                                    sound: sound,
                                    coverData: coverDataByID[sound.id],
                                    isSelected: isSelected,
                                    isSelectable: canSelectMore,
                                    selectionLimitReached: pendingSelectionIDs.count >= 3
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSelectMore)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("Choose Photos")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.selection, trigger: pendingSelectionIDs)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let stableSelection = pendingSelectionIDs.sorted { $0.uuidString < $1.uuidString }
                        onConfirmSelection(stableSelection)
                        isPresented = false
                    } label: {
                        Image(systemName: "checkmark")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(pendingSelectionIDs.isEmpty)
                    .accessibilityLabel("Use selected photos")
                }
            }
        }
    }

    private func toggleSelection(for id: UUID) {
        if pendingSelectionIDs.contains(id) {
            pendingSelectionIDs.remove(id)
        } else if pendingSelectionIDs.count < 3 {
            pendingSelectionIDs.insert(id)
        }
    }
}

private struct JamPhotoCell: View {
    let sound: PhotoSound
    let coverData: Data?
    let isSelected: Bool
    let isSelectable: Bool
    let selectionLimitReached: Bool

    var body: some View {
        VStack(spacing: 8) {
            Color.clear
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .overlay {
                    coverImage
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(isSelected ? Color.white.opacity(0.88) : Color.white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }

            Text(sound.name ?? sound.sequence.displayLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .top)
        }
        .opacity(isSelectable ? 1 : 0.42)
        .contentShape(Rectangle())
        .accessibilityLabel(sound.name ?? sound.sequence.displayLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    @ViewBuilder
    private var coverImage: some View {
        if let coverData, let image = UIImage(data: coverData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Rectangle()
                .fill(.secondary.opacity(0.18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var accessibilityHint: String {
        if isSelected {
            return "Removes this photo from the selection."
        }

        if !isSelectable && selectionLimitReached {
            return "Selection limit reached. Remove a selected photo to choose another."
        }

        return "Adds this photo to the selection."
    }
}
