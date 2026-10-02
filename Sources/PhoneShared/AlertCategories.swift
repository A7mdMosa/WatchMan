import CloudKit
import UserNotifications

/// The notification categories, one per set of buttons.
enum PhoneAlertCategory {
    static let permission = "PERMISSION"
    static let question = "QUESTION"
    static let plan = "PLAN"
    static let note = "NOTE"

    enum Action {
        static let allow = "ALLOW"
        static let deny = "DENY"
        static let approve = "APPROVE"
        static let keepPlanning = "KEEP_PLANNING"
        static let answer = "ANSWER"
        static let reply = "REPLY"
    }

    /// Allow and Approve ask for Face ID first, so nobody runs a command from your lock screen.
    static var all: Set<UNNotificationCategory> {
        typealias A = Action
        let allow = UNNotificationAction(identifier: A.allow, title: "Allow", options: [.authenticationRequired],
                                         icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: A.deny, title: "Deny", options: [.destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let approve = UNNotificationAction(identifier: A.approve, title: "Approve", options: [.authenticationRequired],
                                           icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let keepPlanning = UNTextInputNotificationAction(identifier: A.keepPlanning, title: "Keep Planning", options: [],
                                                         textInputButtonTitle: "Send", textInputPlaceholder: "What should change?")
        let answer = UNTextInputNotificationAction(identifier: A.answer, title: "Answer", options: [],
                                                   textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        let reply = UNTextInputNotificationAction(identifier: A.reply, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        // Locked with previews hidden, the title ("Trailmap finished") still shows instead of only "WatchMan"
        let options: UNNotificationCategoryOptions = [.hiddenPreviewsShowTitle]
        return [
            UNNotificationCategory(identifier: permission, actions: [allow, deny], intentIdentifiers: [], options: options),
            UNNotificationCategory(identifier: question, actions: [answer], intentIdentifiers: [], options: options),
            UNNotificationCategory(identifier: plan, actions: [approve, keepPlanning], intentIdentifiers: [], options: options),
            UNNotificationCategory(identifier: note, actions: [reply], intentIdentifiers: [], options: options),
        ]
    }
}

extension PhoneAlertCategory {
    /// The ones that wait on your answer (the rest are notes: finished, stopped, the limit).
    static let prompts: Set<String> = [permission, question, plan]

    /// When the prompt an alert is about came, if it's about one.
    static func asked(of content: UNNotificationContent) -> Date? {
        let query = CKNotification(fromRemoteNotificationDictionary: content.userInfo) as? CKQueryNotification
        return (query?.recordFields?["asked"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    /// The session an alert is about: from iCloud's push, or from an alert the app posted itself.
    static func sessionId(of content: UNNotificationContent) -> String? {
        if let id = content.userInfo["sessionId"] as? String { return id }
        let query = CKNotification(fromRemoteNotificationDictionary: content.userInfo) as? CKQueryNotification
        return query?.recordFields?["sessionId"] as? String
    }
}
