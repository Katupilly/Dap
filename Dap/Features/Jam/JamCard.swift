import SwiftUI
import UIKit

struct JamCard: View {
    let id: UUID
    let name: String
    let coverData: Data?
    let isEditing: Bool
    @Binding var editingName: String
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onConfirmEdit: () -> Void
    let onCancelEdit: () -> Void

    @State private var coverImage: UIImage?
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                cover
            }
            .buttonStyle(.plain)

            HStack(alignment: .center, spacing: 8) {
                if isEditing {
                    TextField("Jam name", text: $editingName)
                        .font(.subheadline.weight(.semibold))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($isNameFocused)
                        .submitLabel(.done)
                        .onSubmit(onConfirmEdit)
                        .onChange(of: editingName) { _, value in
                            if value.count > 80 {
                                editingName = String(value.prefix(80))
                            }
                        }
                        .lineLimit(1)
                        .onAppear {
                            isNameFocused = true
                        }

                    Button(action: onConfirmEdit) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Save Jam name")

                    Button(action: onCancelEdit) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel Jam name edit")
                } else {
                    Button(action: onOpen) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button("Rename", action: onRename)
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jam actions")
                }
            }
            .frame(minHeight: 28)
        }
        .onAppear { updateCoverImage() }
        .onChange(of: coverData) { _, _ in updateCoverImage() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
    }

    @ViewBuilder
    private var cover: some View {
        ZStack {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.15))
            }
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private func updateCoverImage() {
        coverImage = coverData.flatMap(UIImage.init(data:))
    }
}
