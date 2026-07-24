import SwiftUI

struct JamView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Sessions Yet",
                systemImage: "waveform",
                description: Text("Jam sessions you create will appear here.")
            )
            .navigationTitle("Jam")
        }
    }
}
