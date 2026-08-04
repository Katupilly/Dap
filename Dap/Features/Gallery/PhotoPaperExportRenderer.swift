import SwiftUI
import UIKit

struct PhotoPaperExportRenderer {
    @MainActor
    func render(image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let pixelSize = CGSize(
            width: cgImage.width,
            height: cgImage.height
        )
        let content = PhotoPaperStaticImage(image: image)
            .frame(width: pixelSize.width, height: pixelSize.height)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(pixelSize)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

private struct PhotoPaperStaticImage: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .modifier(PhotoPaperTextureModifier())
    }
}
