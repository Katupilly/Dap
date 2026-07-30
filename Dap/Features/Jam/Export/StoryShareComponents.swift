import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct StoryShareActions<ShareContent: View>: View {
    let isInstagramAvailable: Bool
    let onInstagram: () -> Void
    let shareContent: ShareContent

    init(
        isInstagramAvailable: Bool,
        onInstagram: @escaping () -> Void,
        @ViewBuilder shareContent: () -> ShareContent
    ) {
        self.isInstagramAvailable = isInstagramAvailable
        self.onInstagram = onInstagram
        self.shareContent = shareContent()
    }

    var body: some View {
        VStack(spacing: 10) {
            Button(action: onInstagram) {
                Label(
                    isInstagramAvailable ? "Share to Instagram" : "Instagram Not Installed",
                    systemImage: "camera"
                )
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(StoryPrimaryButtonStyle())
            .opacity(isInstagramAvailable ? 1 : 0.58)
            .accessibilityHint(
                isInstagramAvailable
                    ? "Opens Instagram Stories."
                    : "Shows an Instagram availability message."
            )

            shareContent
                .buttonStyle(StorySecondaryButtonStyle())
        }
    }
}

struct StoryImageExport: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { export in
            export.data
        }
    }
}

struct StoryVideoExport: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { export in
            SentTransferredFile(export.fileURL)
        }
    }
}

struct StoryPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
            .foregroundStyle(.white)
            .background(
                Color.black.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 0.92) : 0.34),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}

struct StorySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
            .foregroundStyle(.primary)
            .background(
                Color.secondary.opacity(configuration.isPressed ? 0.18 : 0.12),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}
