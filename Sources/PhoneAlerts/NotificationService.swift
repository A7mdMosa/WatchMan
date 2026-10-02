import CloudKit
import UserNotifications
import WatchManCore

/// Shapes each alert from iCloud before it shows: the words straight from the Mac, grouped by session, a prompt
/// marked Time Sensitive (it gets through a Focus), and the app icon's count.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let fields = (CKNotification(fromRemoteNotificationDictionary: content.userInfo) as? CKQueryNotification)?.recordFields
        if let title = fields?["title"] as? String, !title.isEmpty { content.title = title }
        if let body = fields?["body"] as? String, !body.isEmpty { content.body = body }
        let sessionId = fields?["sessionId"] as? String
        if let sessionId { content.threadIdentifier = sessionId }
        let prompt = PhoneAlertCategory.prompts.contains(content.categoryIdentifier)
        content.interruptionLevel = prompt ? .timeSensitive : .active
        content.relevanceScore = prompt ? 1 : 0.4
        // The sessions waiting when the app last heard from the Mac, and this one if it waits on you
        var waiting = Set(GlanceStore.load()?.waiting.map(\.id) ?? [])
        if prompt, let sessionId { waiting.insert(sessionId) }
        content.badge = NSNumber(value: waiting.count)
        contentHandler(content)
    }
}
