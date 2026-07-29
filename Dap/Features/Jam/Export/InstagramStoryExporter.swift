import UIKit

enum InstagramStoryExportError: Error, Equatable, LocalizedError {
    case instagramNotInstalled
    case invalidURL
    case pngEncodingFailed
    case renderFailed
    case openFailed

    var errorDescription: String? {
        switch self {
        case .instagramNotInstalled:
            "Instagram is not installed on this device."
        case .invalidURL:
            "Could not create the Instagram Stories link."
        case .pngEncodingFailed:
            "Could not prepare the Jam image for Instagram."
        case .renderFailed:
            "Could not render the Jam story image."
        case .openFailed:
            "Could not open Instagram Stories."
        }
    }
}

struct InstagramStoryExporter {
    private let baseStoriesScheme = "instagram-stories://share"

    @MainActor
    var isInstagramStoriesAvailable: Bool {
        guard let url = URL(string: baseStoriesScheme) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    @MainActor
    func export(backgroundImage image: UIImage) async throws {
        guard let url = storiesShareURL else {
            throw InstagramStoryExportError.invalidURL
        }
        guard UIApplication.shared.canOpenURL(url) else {
            throw InstagramStoryExportError.instagramNotInstalled
        }
        guard let pngData = image.pngData() else {
            throw InstagramStoryExportError.pngEncodingFailed
        }

        UIPasteboard.general.setItems(
            [["com.instagram.sharedSticker.backgroundImage": pngData]],
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
        guard let appID = Bundle.main.object(forInfoDictionaryKey: "FacebookAppID") as? String,
              !appID.isEmpty else {
            return nil
        }
        return URL(string: "\(baseStoriesScheme)?source_application=\(appID)")
    }
}
