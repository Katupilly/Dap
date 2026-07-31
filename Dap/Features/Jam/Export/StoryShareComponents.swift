import Foundation
import ImageIO
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

enum DapExportFileHelper {
    private static let directoryName = "Dap-Exports"

    static func preparePhoto(data: Data, date: Date = Date()) throws -> URL {
        try prepareSingle(data: data, kind: .photo, date: date)
    }

    static func preparePhotos(data: [Data], date: Date = Date()) throws -> [URL] {
        let directory = try resetDirectory()
        return try data.enumerated().map { index, data in
            try write(
                data: data,
                kind: .photos(index: index + 1),
                date: date,
                to: directory
            )
        }
    }

    static func prepareStory(data: Data, date: Date = Date()) throws -> URL {
        try prepareSingle(data: data, kind: .story, date: date)
    }

    static func prepareJamImage(data: Data, name: String, date: Date = Date()) throws -> URL {
        try prepareSingle(data: data, kind: .jam(name: name, fileExtension: "png"), date: date)
    }

    static func prepareJamVideo(
        from sourceURL: URL,
        name: String,
        date: Date = Date()
    ) throws -> URL {
        let directory = try resetDirectory()
        let destination = try uniqueURL(
            in: directory,
            fileName: fileName(for: .jam(name: name, fileExtension: "mp4"), date: date)
        )
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    static func removeTemporaryExports() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    private static func prepareSingle(data: Data, kind: FileKind, date: Date) throws -> URL {
        let directory = try resetDirectory()
        return try write(data: data, kind: kind, date: date, to: directory)
    }

    private static func write(
        data: Data,
        kind: FileKind,
        date: Date,
        to directory: URL
    ) throws -> URL {
        let destination = try uniqueURL(
            in: directory,
            fileName: fileName(for: kind, date: date, data: data)
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func resetDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func uniqueURL(in directory: URL, fileName: String) throws -> URL {
        let fileManager = FileManager.default
        let baseURL = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: baseURL.path) else { return baseURL }

        let stem = baseURL.deletingPathExtension().lastPathComponent
        let pathExtension = baseURL.pathExtension
        var sequence = 2
        while true {
            let candidate = directory.appendingPathComponent(
                "\(stem)-\(sequence).\(pathExtension)"
            )
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            sequence += 1
        }
    }

    private static func fileName(for kind: FileKind, date: Date, data: Data? = nil) -> String {
        switch kind {
        case .photo:
            return "Dap-Photo-\(dateString(date)).\(imageExtension(for: data))"
        case .photos(let index):
            return "Dap-Photos-\(dayString(date))-\(String(format: "%02d", index)).\(imageExtension(for: data))"
        case .story:
            return "Dap-Story-\(dateString(date)).png"
        case .jam(let name, let fileExtension):
            return "Dap-Jam-\(sanitizedJamName(name)).\(fileExtension)"
        }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func imageExtension(for data: Data?) -> String {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source),
              let fileExtension = UTType(typeIdentifier as String)?.preferredFilenameExtension else {
            return "png"
        }
        return fileExtension
    }

    private static func sanitizedJamName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("Untitled Jam") != .orderedSame else {
            return "Untitled"
        }

        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_"))
        let filtered = String(trimmed.unicodeScalars.filter(allowed.contains))
        let components = filtered
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let sanitized = String(components.joined(separator: "-").prefix(80))
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    private enum FileKind {
        case photo
        case photos(index: Int)
        case story
        case jam(name: String, fileExtension: String)
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
