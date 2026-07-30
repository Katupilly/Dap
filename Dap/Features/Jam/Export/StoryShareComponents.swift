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

struct StoryExportChromeBackground: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }
}

struct StoryExportTopBlurFade: View {
    let height: CGFloat

    init(height: CGFloat = 160) {
        self.height = height
    }

    var body: some View {
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
        .frame(height: height)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

struct StoryHeaderGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(isEnabled ? 1 : 0.36))
            .frame(width: 44, height: 44)
            .opacity(isEnabled ? 1 : 0.62)
            .glassEffect(
                .regular
                    .tint(.primary.opacity(isEnabled ? (configuration.isPressed ? 0.10 : 0.06) : 0.03))
                    .interactive(isEnabled),
                in: Circle()
            )
            .contentShape(.interaction, Circle())
    }
}

struct StoryPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
            .foregroundStyle(.primary)
            .background {
                StoryShareButtonContainer(
                    prominence: .primary,
                    isPressed: configuration.isPressed,
                    isEnabled: isEnabled
                )
            }
    }
}

struct StorySecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("ZTTalk-Bold", size: 17, relativeTo: .headline))
            .foregroundStyle(.primary)
            .background {
                StoryShareButtonContainer(
                    prominence: .secondary,
                    isPressed: configuration.isPressed,
                    isEnabled: isEnabled
                )
            }
    }
}

private struct StoryShareButtonContainer: View {
    let prominence: Prominence
    let isPressed: Bool
    let isEnabled: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.primary.opacity(fillOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(strokeOpacity), lineWidth: 1)
            }
    }

    private var fillOpacity: Double {
        guard isEnabled else { return prominence == .primary ? 0.08 : 0.04 }
        switch prominence {
        case .primary:
            return isPressed ? 0.18 : 0.12
        case .secondary:
            return isPressed ? 0.10 : 0.05
        }
    }

    private var strokeOpacity: Double {
        guard isEnabled else { return 0.10 }
        return prominence == .primary ? 0.22 : 0.14
    }

    enum Prominence {
        case primary
        case secondary
    }
}
