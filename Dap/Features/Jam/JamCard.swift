import SwiftUI
import UIKit

struct JamCard: View {
    struct Status: Equatable {
        enum Style: Equatable {
            case neutral
            case success
            case warning
        }

        let text: String
        let style: Style
    }

    let id: UUID
    let name: String
    let coverDescriptor: JamCoverDescriptor
    let detailText: String?
    let status: Status?
    let isEditing: Bool
    let editingPlaceholder: String
    @Binding var editingName: String
    let showsActions: Bool
    let isOpenDisabled: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onConfirmEdit: () -> Void
    let onCancelEdit: () -> Void

    @FocusState private var isNameFocused: Bool
    @ScaledMetric(relativeTo: .body) private var infoAreaHeight = 76.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button(action: onOpen) {
                    cover
                }
                .buttonStyle(.plain)
                .disabled(isOpenDisabled)

                if isEditing {
                    editingControls
                        .padding(8)
                }
            }

            infoArea
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityValue(accessibilityValue)
    }

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow

            if let detailText {
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let status {
                Text(status.text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusForeground(status.style))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusBackground(status.style), in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: infoAreaHeight,
            maxHeight: infoAreaHeight,
            alignment: .top
        )
    }

    @ViewBuilder
    private var titleRow: some View {
        if isEditing {
            TextField(editingPlaceholder, text: $editingName)
                .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))
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
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .onAppear {
                    isNameFocused = true
                }
        } else {
            HStack(alignment: .center, spacing: 8) {
                Button(action: onOpen) {
                    Text(name)
                        .font(.custom("ZTTalk-Bold", size: 15, relativeTo: .subheadline))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(isOpenDisabled)

                if showsActions {
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
        }
    }

    private var editingControls: some View {
        HStack(spacing: 4) {
            Button(action: onConfirmEdit) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save Jam name")

            Button(action: onCancelEdit) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Jam name edit")
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
    }

    @ViewBuilder
    private var cover: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                JamCoverArtwork(
                    descriptor: coverDescriptor,
                    targetSize: CGSize(width: 320, height: 320),
                    cornerRadius: 4
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }

    private func statusForeground(_ style: Status.Style) -> Color {
        switch style {
        case .neutral:
            .secondary
        case .success:
            .green
        case .warning:
            .orange
        }
    }

    private func statusBackground(_ style: Status.Style) -> Color {
        switch style {
        case .neutral:
            Color.secondary.opacity(0.14)
        case .success:
            Color.green.opacity(0.14)
        case .warning:
            Color.orange.opacity(0.14)
        }
    }

    private var accessibilityValue: String {
        [detailText, status?.text]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

struct JamCoverArtwork: View {
    @Environment(\.displayScale) private var displayScale

    let descriptor: JamCoverDescriptor
    let targetSize: CGSize
    let cornerRadius: CGFloat

    @State private var coverImage: UIImage?

    private struct RenderRequest: Hashable {
        let descriptor: JamCoverDescriptor
        let pixelWidth: Int
        let pixelHeight: Int
    }

    var body: some View {
        ZStack {
            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.15))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: renderRequest) {
            coverImage = nil
            let data = await JamCoverRenderer.shared.data(
                for: descriptor,
                size: targetSize,
                scale: displayScale
            )
            guard !Task.isCancelled else { return }
            coverImage = UIImage(data: data, scale: displayScale)
        }
    }

    private var renderRequest: RenderRequest {
        RenderRequest(
            descriptor: descriptor,
            pixelWidth: max(1, Int((targetSize.width * displayScale).rounded())),
            pixelHeight: max(1, Int((targetSize.height * displayScale).rounded()))
        )
    }
}
