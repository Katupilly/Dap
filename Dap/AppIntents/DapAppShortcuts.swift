import AppIntents

struct DapAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TakePhotoIntent(),
            phrases: [
                "Take a photo with \(.applicationName)",
                "Open the camera in \(.applicationName)",
                "Capture with \(.applicationName)"
            ],
            shortTitle: "Take a Photo",
            systemImageName: "camera.fill"
        )

        AppShortcut(
            intent: CreateJamIntent(),
            phrases: [
                "Create a Jam in \(.applicationName)",
                "Start a new Jam with \(.applicationName)",
                "Make music with \(.applicationName)"
            ],
            shortTitle: "Create a Jam",
            systemImageName: "waveform"
        )
    }
}
