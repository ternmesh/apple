// Notifications of what arrives while the user is not looking at it: tapping one opens its
// conversation, and its Reply action sends what was typed there, as the composer would.

import Foundation
import TernKit
import UserNotifications

/// The notification center's delegate. It is made the delegate as the app starts, before the model
/// is made: a tap that launched the app waits here until the model is.
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()

    /// The category of a notification of a message or an invite, which has the Reply action.
    static let category = "item"
    private static let replyAction = "reply"
    private static let peerKey = "peer"
    private static let nodeKey = "node"

    @MainActor private weak var model: NodeModel?
    /// Taps and replies that came before the model.
    @MainActor private var waiting: [UNNotificationResponse] = []

    /// Becomes the delegate, with the Reply action. As the app starts, so that no tap is missed.
    func start() {
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [reply], intentIdentifiers: [], options: []),
        ])
        center.delegate = self
    }

    /// The model, which then takes what waited for it.
    @MainActor func attach(_ model: NodeModel) {
        self.model = model
        let waited = waiting
        waiting = []
        waited.forEach(handle)
    }

    /// What a notification of the conversation `peer` with the node `node` carries.
    static func userInfo(_ peer: Peer, node: UUID) -> [String: String] {
        [peerKey: peer.key, nodeKey: node.uuidString]
    }

    @MainActor private func handle(_ response: UNNotificationResponse) {
        guard let model else { return waiting.append(response) }
        let info = response.notification.request.content.userInfo
        guard let peer = (info[Self.peerKey] as? String).flatMap(Peer.init(key:)),
              let node = (info[Self.nodeKey] as? String).flatMap(UUID.init(uuidString:))
        else { return }
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            model.open(peer, on: node)
        case Self.replyAction:
            if let text = (response as? UNTextInputNotificationResponse)?.userText {
                model.reply(text, to: peer, on: node)
            }
        default:
            break
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.handle(response)
            completionHandler()
        }
    }

    /// The model notifies, while the app is in front, only of a conversation not on screen: show it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
