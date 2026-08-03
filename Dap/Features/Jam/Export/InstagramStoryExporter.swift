import UIKit

enum InstagramStoryExportError: Error, Equatable, LocalizedError {
    case instagramNotInstalled
    case invalidURL
    case jpegEncodingFailed
    case pngEncodingFailed
    case videoReadFailed
    case renderFailed
    case openFailed

    var errorDescription: String? {
        switch self {
        case .instagramNotInstalled:
            "Instagram is not installed on this device."
        case .invalidURL:
            "Could not create the Instagram Stories link."
        case .jpegEncodingFailed:
            "Could not prepare the image for Instagram Stories."
        case .pngEncodingFailed:
            "Could not prepare the Jam image for Instagram."
        case .videoReadFailed:
            "Could not prepare the Jam video for Instagram."
        case .renderFailed:
            "Could not render the Jam story image."
        case .openFailed:
            "Could not open Instagram Stories."
        }
    }
}

struct InstagramStoryShareService {
    private let baseStoriesScheme = "instagram-stories://share"

    @MainActor
    var isInstagramStoriesAvailable: Bool {
        guard let storiesShareURL else { return false }
        return UIApplication.shared.canOpenURL(storiesShareURL)
    }

    @MainActor
    func share(image: UIImage) async throws {
        guard let jpegData = image.jpegData(compressionQuality: 1) else {
            throw InstagramStoryExportError.jpegEncodingFailed
        }
        try await export(
            pasteboardItem: ["com.instagram.sharedSticker.backgroundImage": jpegData]
        )
    }

    @MainActor
    func export(backgroundImage image: UIImage) async throws {
        try await share(image: image)
    }

    @MainActor
    func export(backgroundVideoAt fileURL: URL) async throws {
        let readTask = Task.detached(priority: .userInitiated) {
            try Data(contentsOf: fileURL, options: .mappedIfSafe)
        }
        guard let videoData = try? await readTask.value else {
            throw InstagramStoryExportError.videoReadFailed
        }
        try await export(
            pasteboardItem: ["com.instagram.sharedSticker.backgroundVideo": videoData]
        )
    }

    @MainActor
    private func export(pasteboardItem: [String: Any]) async throws {
        guard let url = storiesShareURL else {
            throw InstagramStoryExportError.invalidURL
        }
        guard UIApplication.shared.canOpenURL(url) else {
            throw InstagramStoryExportError.instagramNotInstalled
        }

        UIPasteboard.general.setItems(
            [pasteboardItem],
            options: [
                .expirationDate: Date().addingTimeInterval(5 * 60)
            ]
        )

        let opened = await UIApplication.shared.open(url, options: [:])
        guard opened else {
            throw InstagramStoryExportError.openFailed
        }
    }

    private var storiesShareURL: URL? {
        URL(string: baseStoriesScheme)
    }
}

typealias InstagramStoryExporter = InstagramStoryShareService
