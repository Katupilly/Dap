import AVFoundation
import Foundation
import UIKit

enum InstagramStoryExportError: Error, Equatable, LocalizedError, Sendable {
    case facebookAppIDMissing
    case instagramNotInstalled
    case invalidURL
    case pngEncodingFailed
    case fileNotFound
    case emptyFile
    case videoReadFailed
    case invalidVideoAsset
    case renderFailed
    case pasteboardWriteFailed
    case openFailed

    var errorDescription: String? {
        switch self {
        case .facebookAppIDMissing:
            "The Facebook App ID is missing from the app configuration."
        case .instagramNotInstalled:
            "Instagram is not installed on this device."
        case .invalidURL:
            "Could not create the Instagram Stories link."
        case .pngEncodingFailed:
            "Could not prepare the Jam image for Instagram."
        case .fileNotFound:
            "The Jam video file is missing."
        case .emptyFile:
            "The Jam video file is empty."
        case .videoReadFailed:
            "Could not prepare the Jam video for Instagram."
        case .invalidVideoAsset:
            "The Jam video does not contain a valid video track or duration."
        case .renderFailed:
            "Could not render the Jam story image."
        case .pasteboardWriteFailed:
            "Could not place the story content on the pasteboard."
        case .openFailed:
            "Could not open Instagram Stories."
        }
    }
}

struct InstagramStoryShareService {
    private let baseStoriesScheme = "instagram-stories://share"

    private enum ContentType: String {
        case image
        case video
    }

    @MainActor
    var isInstagramStoriesAvailable: Bool {
        guard let storiesShareURL else { return false }
        return UIApplication.shared.canOpenURL(storiesShareURL)
    }

    @MainActor
    func share(image: UIImage) async throws {
        guard let pngData = image.pngData() else {
            throw InstagramStoryExportError.pngEncodingFailed
        }
        debugLog("content prepared type=image dataBytes=\(pngData.count)")
        try await export(
            pasteboardItem: ["com.instagram.sharedSticker.backgroundImage": pngData],
            pasteboardKey: "com.instagram.sharedSticker.backgroundImage",
            data: pngData,
            contentType: .image
        )
    }

    @MainActor
    func export(backgroundImage image: UIImage) async throws {
        try await share(image: image)
    }

    @MainActor
    func export(backgroundVideoAt fileURL: URL) async throws {
        let videoData = try await readVideoData(from: fileURL)
        try await validateVideoAsset(at: fileURL)
        debugLog("content prepared type=video dataBytes=\(videoData.count)")
        try await export(
            pasteboardItem: ["com.instagram.sharedSticker.backgroundVideo": videoData],
            pasteboardKey: "com.instagram.sharedSticker.backgroundVideo",
            data: videoData,
            contentType: .video
        )
    }

    @MainActor
    private func export(
        pasteboardItem: [String: Any],
        pasteboardKey: String,
        data: Data,
        contentType: ContentType
    ) async throws {
        guard let url = storiesShareURL else {
            throw facebookAppID == nil
                ? InstagramStoryExportError.facebookAppIDMissing
                : InstagramStoryExportError.invalidURL
        }
        debugLog("URL scheme=\(url.scheme ?? "unknown") source_application=redacted")
        debugLog("canOpenURL=checking")
        guard UIApplication.shared.canOpenURL(url) else {
            debugLog("canOpenURL=false")
            throw InstagramStoryExportError.instagramNotInstalled
        }
        debugLog("canOpenURL=true")

        try preparePasteboard(
            pasteboardItem: pasteboardItem,
            pasteboardKey: pasteboardKey,
            data: data,
            contentType: contentType
        )

        let opened = await UIApplication.shared.open(url, options: [:])
        debugLog("UIApplication.open=\(opened)")
        guard opened else {
            throw InstagramStoryExportError.openFailed
        }
    }

    @MainActor
    private func preparePasteboard(
        pasteboardItem: [String: Any],
        pasteboardKey: String,
        data: Data,
        contentType: ContentType
    ) throws {
        UIPasteboard.general.setItems(
            [pasteboardItem],
            options: [
                .expirationDate: Date().addingTimeInterval(5 * 60)
            ]
        )

        let items = UIPasteboard.general.items
        debugLog(
            "pasteboard type=\(contentType.rawValue) requestedItems=1 availableItems=\(items.count)"
        )
        guard items.count == 1,
              let storedData = items.first?[pasteboardKey] as? Data,
              storedData == data else {
            debugLog("pasteboard verification=false")
            throw InstagramStoryExportError.pasteboardWriteFailed
        }
        debugLog("pasteboard verification=true dataBytes=\(storedData.count)")
    }

    private var storiesShareURL: URL? {
        guard let facebookAppID else { return nil }
        var components = URLComponents(string: baseStoriesScheme)
        components?.queryItems = [
            URLQueryItem(name: "source_application", value: facebookAppID)
        ]
        return components?.url
    }

    private var facebookAppID: String? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "FacebookAppID") as? String else {
            debugLog("FacebookAppID found=false")
            return nil
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            debugLog("FacebookAppID found=false")
            return nil
        }
        let suffix = value.count >= 4 ? String(value.suffix(4)) : "redacted"
        debugLog("FacebookAppID found=true suffix=\(suffix)")
        return value
    }

    @MainActor
    private func readVideoData(from fileURL: URL) async throws -> Data {
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber
        debugLog(
            "file path=\(fileURL.path) exists=\(exists) sizeBytes=\(fileSize?.int64Value ?? 0)"
        )
        guard exists else { throw InstagramStoryExportError.fileNotFound }
        guard let fileSize, fileSize.int64Value > 0 else {
            throw InstagramStoryExportError.emptyFile
        }

        let readTask = Task.detached(priority: .userInitiated) {
            try Data(contentsOf: fileURL, options: .mappedIfSafe)
        }

        do {
            let data = try await readTask.value
            guard !data.isEmpty else { throw InstagramStoryExportError.emptyFile }
            debugLog("Data created bytes=\(data.count)")
            return data
        } catch let error as InstagramStoryExportError {
            throw error
        } catch {
            let stillExists = FileManager.default.fileExists(atPath: fileURL.path)
            throw stillExists
                ? InstagramStoryExportError.videoReadFailed
                : InstagramStoryExportError.fileNotFound
        }
    }

    @MainActor
    private func validateVideoAsset(at fileURL: URL) async throws {
        let asset = AVURLAsset(url: fileURL)

        do {
            let duration = try await asset.load(.duration)
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw InstagramStoryExportError.invalidVideoAsset
            }

            let durationSeconds = CMTimeGetSeconds(duration)
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                throw InstagramStoryExportError.invalidVideoAsset
            }

            let size = try await videoTrack.load(.naturalSize)
            let videoDescriptions = try await videoTrack.load(.formatDescriptions)
            let videoCodec = videoDescriptions.first.map(CMFormatDescriptionGetMediaSubType)
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            let audioDescriptions = try await audioTrack?.load(.formatDescriptions) ?? []
            let audioCodec = audioDescriptions.first.map(CMFormatDescriptionGetMediaSubType)

            debugLog(
                "video duration=\(durationSeconds)s dimensions=\(Int(size.width.rounded()))x\(Int(size.height.rounded())) "
                    + "videoCodec=\(mediaSubtypeDescription(videoCodec)) "
                    + "audioCodec=\(mediaSubtypeDescription(audioCodec)) audioTrack=\(audioTrack != nil)"
            )
        } catch let error as InstagramStoryExportError {
            throw error
        } catch {
            debugLog("video asset read error=\(error.localizedDescription)")
            throw InstagramStoryExportError.videoReadFailed
        }
    }

#if DEBUG
    @MainActor
    func diagnoseStoryPayloads(knownVideoAt knownVideoURL: URL, dapVideoAt dapVideoURL: URL) async {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        do {
            guard let data = image.pngData() else {
                throw InstagramStoryExportError.pngEncodingFailed
            }
            try preparePasteboard(
                pasteboardItem: ["com.instagram.sharedSticker.backgroundImage": data],
                pasteboardKey: "com.instagram.sharedSticker.backgroundImage",
                data: data,
                contentType: .image
            )
            debugLog("diagnostic case=image PNG passed")
        } catch {
            debugLog("diagnostic case=image PNG error=\(error.localizedDescription)")
        }

        for (label, url) in [("known MP4", knownVideoURL), ("Dap MP4", dapVideoURL)] {
            do {
                let data = try await readVideoData(from: url)
                try await validateVideoAsset(at: url)
                try preparePasteboard(
                    pasteboardItem: ["com.instagram.sharedSticker.backgroundVideo": data],
                    pasteboardKey: "com.instagram.sharedSticker.backgroundVideo",
                    data: data,
                    contentType: .video
                )
                debugLog("diagnostic case=\(label) passed")
            } catch {
                debugLog("diagnostic case=\(label) error=\(error.localizedDescription)")
            }
        }
    }
#endif

    private func mediaSubtypeDescription(_ subtype: FourCharCode?) -> String {
        guard let subtype else { return "unavailable" }
        let bytes = [
            UInt8((subtype >> 24) & 0xFF),
            UInt8((subtype >> 16) & 0xFF),
            UInt8((subtype >> 8) & 0xFF),
            UInt8(subtype & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(subtype)"
    }

#if DEBUG
    private func debugLog(_ message: @autoclosure () -> String) {
        print("[InstagramStory] \(message())")
    }
#else
    private func debugLog(_ message: @autoclosure () -> String) {}
#endif
}

typealias InstagramStoryExporter = InstagramStoryShareService
