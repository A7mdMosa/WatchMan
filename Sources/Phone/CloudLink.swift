import CloudKit
import UIKit
import UserNotifications
import WatchManCore

/// The phone's side of the link: reads the sessions, chats and usage the Mac keeps in your private iCloud
/// database, and leaves your answers there for the Mac to carry out.
@MainActor
final class CloudLink: PhoneLink {
    private var database: CKDatabase { CloudRecords.container.privateCloudDatabase }
    /// Every record seen so far, and where the change feed left off, so each fetch reads only what changed.
    private var sessions: [String: SessionSnapshot] = [:]
    private var status: MacStatus?
    private var changeToken: CKServerChangeToken?
    private var subscribed = false

    enum LinkError: LocalizedError {
        case noAccount, notStarted
        var errorDescription: String? {
            switch self {
            case .noAccount: "Sign in to iCloud on this iPhone, with the same Apple ID as the Mac."
            case .notStarted: "Open WatchMan on your Mac to link it."
            }
        }
    }

    func fetch() async throws -> PhoneState {
        guard try await CloudRecords.container.accountStatus() == .available else { throw LinkError.noAccount }
        await subscribeIfNeeded()
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: CloudRecords.zoneID, since: changeToken)
                for (_, result) in changes.modificationResultsByID {
                    guard case .success(let modification) = result else { continue }
                    let record = modification.record
                    switch record.recordType {
                    case CloudRecords.Kind.session:
                        if let snapshot = CloudRecords.value(SessionSnapshot.self, in: record) { sessions[snapshot.id] = snapshot }
                    case CloudRecords.Kind.status:
                        status = CloudRecords.value(MacStatus.self, in: record)
                    default:
                        break
                    }
                }
                for deletion in changes.deletions where deletion.recordType == CloudRecords.Kind.session {
                    sessions[deletion.recordID.recordName] = nil
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            throw LinkError.notStarted
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            sessions = [:]
            return try await fetch()
        }
        return PhoneState(sessions: Array(sessions.values), usage: status?.usage, macName: status?.macName ?? "your Mac",
                          updated: status?.updated ?? .distantPast, extras: status?.extras)
    }

    func chat(for sessionId: String) async throws -> ChatSnapshot? {
        do {
            let record = try await database.record(for: CloudRecords.id(CloudRecords.chatName(sessionId)))
            return CloudRecords.value(ChatSnapshot.self, in: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func send(_ command: PhoneCommand) async throws {
        let record = try CloudRecords.record(CloudRecords.Kind.command, name: command.id.uuidString, command)
        _ = try await database.save(record)
    }

    /// A silent push whenever the Mac changes a session or the usage, so the app refreshes by itself.
    private func subscribeIfNeeded() async {
        guard !subscribed else { return }
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        var subscriptions: [CKSubscription] = []
        for (kind, name) in [(CloudRecords.Kind.session, "watchman-sessions"), (CloudRecords.Kind.status, "watchman-status")] {
            let subscription = CKQuerySubscription(recordType: kind, predicate: NSPredicate(value: true), subscriptionID: name,
                                                   options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
            subscription.zoneID = CloudRecords.zoneID
            subscription.notificationInfo = info
            subscriptions.append(subscription)
        }
        // The alerts: visible notifications with each kind's buttons
        for (kind, category) in [(CloudRecords.Alert.permission, PhoneAlertCategory.permission),
                                 (CloudRecords.Alert.question, PhoneAlertCategory.question),
                                 (CloudRecords.Alert.plan, PhoneAlertCategory.plan),
                                 (CloudRecords.Alert.note, PhoneAlertCategory.note)] {
            let alert = CKSubscription.NotificationInfo()
            alert.titleLocalizationKey = "WM_TITLE"
            alert.titleLocalizationArgs = ["title"]
            alert.alertLocalizationKey = "WM_BODY"
            alert.alertLocalizationArgs = ["body"]
            alert.soundName = "default"
            alert.category = category
            // The words too, for the alert extension (it marks prompts Time Sensitive and groups by session)
            alert.desiredKeys = ["sessionId", "title", "body", "asked"]
            alert.shouldSendMutableContent = true
            // One alert per session: a newer one replaces the last instead of piling up
            alert.collapseIDKey = "sessionId"
            let subscription = CKQuerySubscription(recordType: kind, predicate: NSPredicate(value: true),
                                                   subscriptionID: "watchman-alert-" + kind, options: [.firesOnRecordCreation])
            subscription.zoneID = CloudRecords.zoneID
            subscription.notificationInfo = alert
            subscriptions.append(subscription)
        }
        if (try? await database.modifySubscriptions(saving: subscriptions, deleting: [])) != nil {
            subscribed = true
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
}

/// Receives iCloud's pushes: silent ones refresh the app; a tap on an alert's button answers the Mac; a tap on
/// the alert opens its session.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(PhoneAlertCategory.all)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        return true
    }

    /// iCloud's silent push: the Mac changed something. Read it before iOS puts the app back to sleep, so the
    /// widgets, the Live Activity and the icon's count follow.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let store = PhoneStore.current else { return .noData }
        await store.refresh()
        return store.problem == nil ? .newData : .failed
    }

    /// Alerts show even while the app is open, except for the session whose page you're looking at.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let sessionId = PhoneAlertCategory.sessionId(of: notification.request.content)
        let showing = await MainActor.run { sessionId.map { PhoneStore.current?.isShowing($0) == true } ?? false }
        return showing ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let sessionId = PhoneAlertCategory.sessionId(of: response.notification.request.content),
              !sessionId.isEmpty else { return }
        let typed = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        typealias A = PhoneAlertCategory.Action
        let kind: PhoneCommand.Kind?
        switch response.actionIdentifier {
        case A.allow, A.approve: kind = .allow
        case A.deny: kind = .deny(message: nil)
        case A.keepPlanning: kind = .deny(message: typed?.isEmpty == false ? typed : nil)
        case A.answer: kind = typed?.isEmpty == false ? .answer(QuestionAnswers(response: typed)) : nil
        case A.reply: kind = typed?.isEmpty == false ? .reply(typed!) : nil
        case let id where id.hasPrefix("CHOICE_"):
            // A question's choice button, from the notification extension
            kind = Int(id.dropFirst("CHOICE_".count)).map { .pick($0) }
        default:
            // A tap on the alert itself: open its session
            await MainActor.run { NotificationCenter.default.post(name: .watchManPhoneOpen, object: sessionId) }
            return
        }
        guard let kind else { return }
        do {
            // A button answers the prompt its alert showed, never the next one
            try await PromptAnswer.send(kind, to: sessionId, asked: PhoneAlertCategory.asked(of: response.notification.request.content))
        } catch {
            // Answered from the lock screen and it didn't go: say so, rather than leave you thinking it did
            let content = UNMutableNotificationContent()
            content.title = "Your answer didn't reach your Mac"
            content.body = "iCloud couldn't take it. Open WatchMan to answer again."
            content.userInfo = ["sessionId": sessionId]
            content.threadIdentifier = sessionId
            try? await center.add(UNNotificationRequest(identifier: "failed-" + sessionId, content: content, trigger: nil))
        }
    }
}

extension Notification.Name {
    /// Open a session's page (the object is its id), from a tapped alert.
    static let watchManPhoneOpen = Notification.Name("watchManPhoneOpen")
}
