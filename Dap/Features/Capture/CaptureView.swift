import SwiftUI
import PhotosUI

struct CaptureView: View {
    let library: PhotoLibraryViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showError  = false
    @State private var errorText  = ""

    var body: some View {
        NavigationStack {
            Group {
                if library.isImporting {
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
                        .disabled(library.isImporting)
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
                // Camera capture — implemented in a later step
            } label: {
                Label("Take Photo", systemImage: "camera")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.regularMaterial,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .opacity(0.45)
            }
            .buttonStyle(.plain)
            .disabled(true)

            Spacer()
        }
        .padding()
    }
}
