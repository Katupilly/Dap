import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct JamStoryExportSheet: View {
    let snapshot: JamStoryExportSnapshot
    @Binding var isPresented: Bool

    @State private var renderState: RenderState = .preparing
    @State private var hasStartedRender = false
    @State private var instagramError: InstagramStoryExportError?

    private let renderer = JamStoryRenderer()
    private let instagramExporter = InstagramStoryExporter()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    preview
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Export Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        isPresented = false
                    }
                }
            }
        }
        .task {
            await prepareOnce()
        }
        .alert("Instagram Stories", isPresented: instagramErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(instagramError?.localizedDescription ?? "Could not share to Instagram Stories.")
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch renderState {
        case .preparing:
            previewFrame {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                    Text("Preparing story image…")
                        .font(.custom("ZTTalk-Bold", size: 16, relativeTo: .subheadline))
                        .foregroundStyle(.white.opacity(0.74))
                }
            }
        case .ready(let result):
            Image(uiImage: result.image)
                .resizable()
                .scaledToFit()
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
        case .failed:
            previewFrame {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34, weight: .semibold))
                    Text("Could not prepare this story image.")
                        .font(.custom("ZTTalk-Bold", size: 16, relativeTo: .subheadline))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.78))
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch renderState {
        case .ready(let result):
            let instagramAvailable = instagramExporter.isInstagramStoriesAvailable

            VStack(spacing: 10) {
                Button {
                    Task { await shareToInstagram(result.image) }
                } label: {
                    Label(
                        instagramAvailable ? "Share to Instagram" : "Instagram Not Installed",
                        systemImage: "camera"
                    )
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(JamStoryPrimaryButtonStyle())
                .opacity(instagramAvailable ? 1 : 0.58)
                .accessibilityHint(instagramAvailable ? "Opens Instagram Stories." : "Shows an Instagram availability message.")

                ShareLink(
                    item: JamStoryImageExport(data: result.pngData),
                    preview: SharePreview(snapshot.jamName, image: Image(uiImage: result.image))
                ) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(JamStorySecondaryButtonStyle())
            }
        case .preparing:
            EmptyView()
        case .failed:
            Button {
                isPresented = false
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(JamStorySecondaryButtonStyle())
        }
    }

    private func previewFrame<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.88), .black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )
            content()
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @MainActor
    private func prepareOnce() async {
        guard !hasStartedRender else { return }
        hasStartedRender = true
        renderState = .preparing

        do {
            let result = try await renderer.render(snapshot: snapshot)
            renderState = .ready(result)
        } catch {
            renderState = .failed
        }
    }

    @MainActor
    private func shareToInstagram(_ image: UIImage) async {
        do {
            try await instagramExporter.export(backgroundImage: image)
        } catch let error as InstagramStoryExportError {
            instagramError = error
        } catch {
            instagramError = .openFailed
        }
    }

    private var instagramErrorPresented: Binding<Bool> {
        Binding(
            get: { instagramError != nil },
            set: { if !$0 { instagramError = nil } }
        )
    }

    private enum RenderState {
        case preparing
        case ready(JamStoryRenderResult)
        case failed
    }
}

private struct JamStoryImageExport: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { export in
            export.data
        }
    }
}

private struct JamStoryPrimaryButtonStyle: ButtonStyle {
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

private struct JamStorySecondaryButtonStyle: ButtonStyle {
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
