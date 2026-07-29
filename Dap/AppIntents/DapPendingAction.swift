import Foundation

enum DapPendingAction: String, Codable, Sendable {
    case openCapture
    case createJam
}

struct DapPendingActionRequest: Codable, Equatable, Sendable {
    let id: UUID
    let action: DapPendingAction
}

enum DapPendingActionStore {
    private static let defaultsKey = "DapPendingActionRequest"

    static func enqueue(_ action: DapPendingAction, defaults: UserDefaults = .standard) {
        let request = DapPendingActionRequest(id: UUID(), action: action)
        guard let data = try? JSONEncoder().encode(request) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func consume(defaults: UserDefaults = .standard) -> DapPendingActionRequest? {
        guard let data = defaults.data(forKey: defaultsKey),
              let request = try? JSONDecoder().decode(DapPendingActionRequest.self, from: data) else {
            return nil
        }

        defaults.removeObject(forKey: defaultsKey)
        return request
    }
}
