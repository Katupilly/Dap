import Foundation
import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum StoryShareTemplate: String, CaseIterable, Hashable, Identifiable, Sendable {
    case plain
    case dap

    var id: Self { self }
}

struct StorySharePreview: Identifiable {
    let template: StoryShareTemplate
    let image: UIImage?
    let isLoading: Bool

    var id: StoryShareTemplate { template }
}

/// Shared visual surface for the Photo and Jam Share covers. Export work stays
/// in the owning feature; this view only renders previews and forwards intent.
struct StoryShareSurface: View {
    let previews: [StorySharePreview]
    let selection: StoryShareTemplate
    let isInstagramAvailable: Bool
    let isStoriesLoading: Bool
    let isShareLoading: Bool
    let isStoriesEnabled: Bool
    let isShareEnabled: Bool
    let onSelect: (StoryShareTemplate) -> Void
    let onStories: () -> Void
    let onShare: () -> Void
    var aspectRatio: CGFloat = 317.4 / 541.2

    @State private var scrollTarget: StoryShareTemplate?

    var body: some View {
        GeometryReader { proxy in
            let cardSpacing: CGFloat = 17.2
            let leadingPadding: CGFloat = 20
            let peek = min(48, max(32, proxy.size.width * 0.098))
            let widthAllowedByScreen = max(0, proxy.size.width - leadingPadding - cardSpacing - peek)
            let cardTopGap: CGFloat = 24
            let dotsSize: CGFloat = 8
            let dotsGap: CGFloat = 22
            let actionsGap: CGFloat = 40
            let actionsHeight: CGFloat = 74
            let bottomSafeArea = proxy.safeAreaInsets.bottom
            let availableCardHeight = max(
                0,
                proxy.size.height
                    - cardTopGap
                    - dotsGap
                    - dotsSize
                    - actionsGap
                    - actionsHeight
                    - bottomSafeArea
            )
            let widthAllowedByHeight = availableCardHeight * aspectRatio
            let cardWidth = min(widthAllowedByScreen, widthAllowedByHeight)
            let cardSize = CGSize(width: cardWidth, height: cardWidth / aspectRatio)

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: cardTopGap)
                    .accessibilityHidden(true)

                ScrollView(.horizontal) {
                    HStack(spacing: cardSpacing) {
                        ForEach(StoryShareTemplate.allCases) { template in
                            StorySharePreviewCard(
                                preview: previews.first(where: { $0.template == template })
                                    ?? StorySharePreview(template: template, image: nil, isLoading: true),
                                isSelected: selection == template,
                                size: cardSize,
                                onSelect: { onSelect(template) }
                            )
                            .id(template)
                        }
                    }
                    .padding(.leading, leadingPadding)
                    .padding(.trailing, leadingPadding)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .frame(height: cardSize.height)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $scrollTarget)
                .onAppear { scrollTarget = selection }
                .onChange(of: selection) { _, value in
                    guard scrollTarget != value else { return }
                    scrollTarget = value
                }
                .onChange(of: scrollTarget) { _, value in
                    guard let value, value != selection else { return }
                    onSelect(value)
                }

                HStack(spacing: 6) {
                    ForEach(StoryShareTemplate.allCases) { template in
                        Circle()
                            .fill(selection == template ? Color.primary : Color.secondary.opacity(0.28))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, dotsGap)
                .accessibilityHidden(true)

                HStack(spacing: 18) {
                    StoryShareActionButton(
                        title: "Stories",
                        systemImage: nil,
                        imageAsset: "InstagramStories",
                        isLoading: isStoriesLoading,
                        isEnabled: isInstagramAvailable && isStoriesEnabled,
                        accessibilityLabel: "Share to Instagram Stories",
                        buttonSize: CGSize(width: 100, height: actionsHeight),
                        labelFont: .system(size: 17, weight: .semibold),
                        action: onStories
                    )

                    StoryShareActionButton(
                        title: "Share",
                        systemImage: "square.and.arrow.up",
                        imageAsset: nil,
                        isLoading: isShareLoading,
                        isEnabled: isShareEnabled,
                        accessibilityLabel: "Share",
                        buttonSize: CGSize(width: 100, height: actionsHeight),
                        labelFont: .system(size: 17, weight: .semibold),
                        action: onShare
                    )
                }
                .padding(.top, actionsGap)
                .padding(.bottom, bottomSafeArea)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
    }
}

struct StoryShareActions: View {
    let isInstagramAvailable: Bool
    let isStoriesLoading: Bool
    let isShareLoading: Bool
    let isStoriesEnabled: Bool
    let isShareEnabled: Bool
    let onStories: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            StoryShareActionButton(
                title: "Stories",
                systemImage: nil,
                imageAsset: "InstagramStories",
                isLoading: isStoriesLoading,
                isEnabled: isInstagramAvailable && isStoriesEnabled,
                accessibilityLabel: "Share to Instagram Stories",
                action: onStories
            )

            StoryShareActionButton(
                title: "Share",
                systemImage: "square.and.arrow.up",
                imageAsset: nil,
                isLoading: isShareLoading,
                isEnabled: isShareEnabled,
                accessibilityLabel: "Share",
                action: onShare
            )
        }
    }
}

private struct StorySharePreviewCard: View {
    let preview: StorySharePreview
    let isSelected: Bool
    let size: CGSize
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                RoundedRectangle(cornerRadius: 19.4, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))

                if let image = preview.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 19.4, style: .continuous))
                } else if preview.isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel("Loading")
                } else {
                    RoundedRectangle(cornerRadius: 19.4, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 19.4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19.4, style: .continuous)
                    .stroke(
                        isSelected ? Color.primary : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 3.2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preview.template == .plain ? "Photo only" : "Dap template")
        .accessibilityValue(preview.isLoading ? "Loading" : (isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct StoryShareActionButton: View {
    let title: String
    let systemImage: String?
    let imageAsset: String?
    let isLoading: Bool
    let isEnabled: Bool
    let accessibilityLabel: String
    let buttonSize: CGSize
    let labelFont: Font
    let action: () -> Void

    init(
        title: String,
        systemImage: String?,
        imageAsset: String?,
        isLoading: Bool,
        isEnabled: Bool,
        accessibilityLabel: String,
        buttonSize: CGSize = CGSize(width: 100, height: 70),
        labelFont: Font = .system(size: 13, weight: .semibold),
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.imageAsset = imageAsset
        self.isLoading = isLoading
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.buttonSize = buttonSize
        self.labelFont = labelFont
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else if let imageAsset {
                        Image(imageAsset)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 20, weight: .medium))
                    }
                }
                .frame(width: 20, height: 20)

                Text(title)
                    .font(labelFont)
                    .lineLimit(1)
            }
            .frame(width: buttonSize.width, height: buttonSize.height)
            .foregroundStyle(.primary)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isLoading ? "Loading" : "")
    }
}

struct StoryShareHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(StoryHeaderGlassButtonStyle(size: 48))
            .frame(width: 48, height: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .frame(height: 62, alignment: .center)
    }
}

enum PhotoSaveResult: Equatable, Sendable {
    case success
    case failure
}

struct PhotoSaveToastEvent: Equatable, Identifiable, Sendable {
    let id = UUID()
    let result: PhotoSaveResult

    @MainActor
    static func make(for result: PhotoSaveResult) -> Self {
        let event = Self(result: result)
        let feedback = UINotificationFeedbackGenerator()
        feedback.prepare()
        switch result {
        case .success:
            feedback.notificationOccurred(.success)
        case .failure:
            feedback.notificationOccurred(.error)
        }
        return event
    }
}

private struct PhotoSaveToast: View {
    let result: PhotoSaveResult
    @Environment(\.colorScheme) private var colorScheme

    private var icon: String {
        switch result {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.circle.fill"
        }
    }

    private var message: String {
        switch result {
        case .success: "Saved to Photos"
        case .failure: "Couldn’t save photo"
        }
    }

    private var contentColor: Color {
        colorScheme == .dark
            ? .white
            : Color(red: 26 / 255, green: 26 / 255, blue: 30 / 255)
    }

    var body: some View {
        Label(message, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(contentColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(contentColor.opacity(0.18), lineWidth: 0.75)
            }
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.28 : 0.14),
                radius: 12,
                y: 4
            )
            .accessibilityElement(children: .combine)
    }
}

private struct PhotoSaveToastMotion: ViewModifier {
    let y: CGFloat
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: y)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

private extension AnyTransition {
    static var photoSaveToast: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: PhotoSaveToastMotion(y: -10, scale: 0.94, opacity: 0),
                identity: PhotoSaveToastMotion(y: 0, scale: 1, opacity: 1)
            ),
            removal: .modifier(
                active: PhotoSaveToastMotion(y: -10, scale: 0.94, opacity: 0),
                identity: PhotoSaveToastMotion(y: 0, scale: 1, opacity: 1)
            )
        )
    }
}

private struct PhotoSaveToastModifier: ViewModifier {
    @Binding var event: PhotoSaveToastEvent?
    @State private var visibleEvent: PhotoSaveToastEvent?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var toastAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.18)
            : .spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.05)
    }

    private var toastTransition: AnyTransition {
        reduceMotion ? .opacity : .photoSaveToast
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    if let visibleEvent {
                        PhotoSaveToast(result: visibleEvent.result)
                            .frame(maxWidth: .infinity)
                            .padding(.top, max(proxy.safeAreaInsets.top + 8, 68))
                            .transition(toastTransition)
                            .zIndex(1)
                    }
                }
                .allowsHitTesting(false)
            }
            .onChange(of: event) { _, newEvent in
                guard let newEvent else { return }
                withAnimation(toastAnimation) {
                    visibleEvent = newEvent
                }
            }
            .task(id: event?.id) {
                guard let event else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self.event?.id == event.id else { return }
                withAnimation(toastAnimation) {
                    visibleEvent = nil
                    self.event = nil
                }
            }
    }
}

extension View {
    func photoSaveToast(_ event: Binding<PhotoSaveToastEvent?>) -> some View {
        modifier(PhotoSaveToastModifier(event: event))
    }
}

// UIKit invokes the activity on main; the lock also protects the asynchronous PhotoKit completion.
final class SavePhotoActivity: UIActivity, @unchecked Sendable {
    static let activityType = UIActivity.ActivityType("com.pedrolima.DapNext.savePhoto")

    private let onResult: (PhotoSaveResult) -> Void
    private let stateLock = NSLock()
    private var image: UIImage?
    private var didFinish = false

    init(onResult: @escaping (PhotoSaveResult) -> Void) {
        self.onResult = onResult
        super.init()
    }

    override var activityType: UIActivity.ActivityType? { Self.activityType }
    override var activityTitle: String? { "Save to Photos" }
    override var activityImage: UIImage? { UIImage(systemName: "square.and.arrow.down") }
    override class var activityCategory: UIActivity.Category { .action }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        activityItems.contains { $0 is UIImage }
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        stateLock.lock()
        image = activityItems.compactMap { $0 as? UIImage }.first
        stateLock.unlock()
    }

    override func perform() {
        stateLock.lock()
        let image = image
        stateLock.unlock()
        guard let image else {
            finish(.failure)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self, image] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                finish(.failure)
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { [weak self] success, _ in
                self?.finish(success ? .success : .failure)
            }
        }
    }

    private func finish(_ result: PhotoSaveResult) {
        stateLock.lock()
        guard !didFinish else {
            stateLock.unlock()
            return
        }
        didFinish = true
        stateLock.unlock()
        let callback = onResult
        DispatchQueue.main.async { [weak self] in
            self?.activityDidFinish(result == .success)
            callback(result)
        }
    }
}

struct NativeImageShareViewController: UIViewControllerRepresentable {
    let image: UIImage
    let onSaveResult: (PhotoSaveResult) -> Void
    let onDismiss: () -> Void

    init(
        image: UIImage,
        onSaveResult: @escaping (PhotoSaveResult) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.image = image
        self.onSaveResult = onSaveResult
        self.onDismiss = onDismiss
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [image],
            applicationActivities: [SavePhotoActivity(onResult: onSaveResult)]
        )
        controller.excludedActivityTypes = [.saveToCameraRoll]
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in
                onDismiss()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
    let size: CGFloat

    init(size: CGFloat = 44) {
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(isEnabled ? 1 : 0.36))
            .frame(width: size, height: size)
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
