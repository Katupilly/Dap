import SwiftUI

struct GalleryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Photos Yet",
                systemImage: "photo.stack",
                description: Text("Musical photos you create will appear here.")
            )
            .navigationTitle("Gallery")
        }
    }
}
