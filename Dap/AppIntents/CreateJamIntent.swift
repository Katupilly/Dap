import AppIntents

struct CreateJamIntent: AppIntent {
    static let title: LocalizedStringResource = "Create a Jam"
    static let description = IntentDescription("Open Dap to start a new Jam.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        DapPendingActionStore.enqueue(.createJam)
        return .result(dialog: "Opening a new Jam in Dap.")
    }
}
