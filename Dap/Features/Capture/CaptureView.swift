import SwiftUI
import PhotosUI

struct CaptureView: View {
    let library: PhotoLibraryViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showError  = false
    @State private var errorText  = ""
    @State private var mode: Mode = .options

    var body: some View {
        NavigationStack {
            Group {
                if mode == .camera {
                    CameraView(
                        onPhotoData: { try await library.importPhotoData($0) },
                        onSuccess: { dismiss() },
                        onBack: { mode = .options }
                    )
                } else if library.isImporting {
                    processingView
                } else {
                    optionsView
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(library.isImporting || mode == .camera)
                }
            }
            .alert("Import Failed", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText)
            }
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let item = newValue else { return }
            Task {
                do {
                    try await library.importPhoto(from: item)
                    selectedPhoto = nil   // Allow re-selecting the same photo later.
                    dismiss()
                } catch {
                    selectedPhoto = nil   // Clear so the picker can reopen.
                    errorText = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    // MARK: - Sub-views

    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Processing…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var optionsView: some View {
        VStack(spacing: 24) {
            // Import from Photo Library
            PhotosPicker(
                selection: $selectedPhoto,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Import Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            // Take Photo — visually present, not yet implemented
            Button {
                mode = .camera
            } label: {
                Label("Camera", systemImage: "camera")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding()
    }

    private enum Mode {
        case options
        case camera
    }
}
