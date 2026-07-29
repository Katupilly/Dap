import AppIntents

struct TakePhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Take a Photo"
    static let description = IntentDescription("Open Dap directly to the camera.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        DapPendingActionStore.enqueue(.openCapture)
        return .result(dialog: "Opening the Dap camera.")
    }
}
