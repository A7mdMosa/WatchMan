import CloudKit
import UIKit
import UserNotifications
import WatchManCore

/// The phone's side of the link: reads the sessions, chats and usage the Mac keeps in your private iCloud
/// database, and leaves your answers there for the Mac to carry out.
@MainActor
final class CloudLink: PhoneLink {
    private var database: CKDatabase { CloudRecords.container.privateCloudDatabase }
    /// Every record seen so far, and where the change feed left off, so each fetch reads only what changed. Kept on
    /// disk too: the app opens on the last sessions it knew, then catches up.
    private var sessions: [String: SessionSnapshot] = [:]
    private var status: MacStatus?
    private var changeToken: CKServerChangeToken?
    /// The chats whose page was opened: the change feed brings their new messages; others load when asked.
    private var followed: Set<String> = []
    private var accountChecked = false

    enum LinkError: LocalizedError {
        case noAccount, notStarted
        var errorDescription: String? {
            switch self {
            case .noAccount: "Sign in to iCloud on this iPhone, with the same Apple ID as the Mac."
            case .notStarted: "Install WatchMan for Mac (free) and open it with the same Apple ID. Your Claude Code sessions show up here."
            }
        }
    }

    init() {
        if let cache = LinkCache.load() {
            sessions = Dictionary(cache.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            status = cache.status
            changeToken = cache.token
        }
    }

    func cachedState() -> PhoneState? {
        guard !sessions.isEmpty || status != nil else { return nil }
        return state(chats: [:])
    }

    func fetch() async throws -> PhoneState {
        if !accountChecked {
            guard try await CloudRecords.container.accountStatus() == .available else { throw LinkError.noAccount }
            accountChecked = true
        }
        // Subscribing doesn't hold up the sessions
        Task { await subscribeIfNeeded() }
        var chats: [String: ChatSnapshot] = [:]
        do {
            // The feed without its fields first: only sessions, the status and opened chats are worth downloading
            var wanted: [CKRecord.ID] = []
            var more = true
            var token = changeToken
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: CloudRecords.zoneID, since: token, desiredKeys: [])
                for (id, result) in changes.modificationResultsByID {
                    guard case .success(let modification) = result else { continue }
                    switch modification.record.recordType {
                    case CloudRecords.Kind.session, CloudRecords.Kind.status: wanted.append(id)
                    case CloudRecords.Kind.chat where followed.contains(String(id.recordName.dropFirst("chat-".count))):
                        wanted.append(id)
                    default: break
                    }
                }
                for deletion in changes.deletions where deletion.recordType == CloudRecords.Kind.session {
                    sessions[deletion.recordID.recordName] = nil
                }
                token = changes.changeToken
                more = changes.moreComing
            }
            for batch in stride(from: 0, to: wanted.count, by: 200).map({ Array(wanted[$0..<min($0 + 200, wanted.count)]) }) {
                for (_, result) in try await database.records(for: batch) {
                    guard case .success(let record) = result else { continue }
                    switch record.recordType {
                    case CloudRecords.Kind.session:
                        if let snapshot = CloudRecords.value(SessionSnapshot.self, in: record) { sessions[snapshot.id] = snapshot }
                    case CloudRecords.Kind.status:
                        status = CloudRecords.value(MacStatus.self, in: record)
                    case CloudRecords.Kind.chat:
                        if let chat = CloudRecords.value(ChatSnapshot.self, in: record) { chats[chat.sessionId] = chat }
                    default: break
                    }
                }
            }
            changeToken = token
            LinkCache(sessions: Array(sessions.values), status: status, token: changeToken).save()
        } catch let error as CKError where error.code == .zoneNotFound {
            throw LinkError.notStarted
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            sessions = [:]
            return try await fetch()
        }
        return state(chats: chats)
    }

    private func state(chats: [String: ChatSnapshot]) -> PhoneState {
        PhoneState(sessions: Array(sessions.values), usage: status?.usage, macName: status?.macName ?? "your Mac",
                   updated: status?.updated ?? .distantPast, extras: status?.extras, chats: chats)
    }

    func chat(for sessionId: String) async throws -> ChatSnapshot? {
        followed.insert(sessionId)
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

    /// A silent push whenever the Mac changes a session or the usage, so the app refreshes by itself. Saved at most
    /// once a day (and whenever what they ask for changes), since iCloud keeps them.
    private static let subscriptionsVersion = 4
    private var subscribing = false

    private func subscribeIfNeeded() async {
        UIApplication.shared.registerForRemoteNotifications()
        let defaults = UserDefaults.standard
        let fresh = Date().timeIntervalSince1970 - defaults.double(forKey: "subscribedAt") < 24 * 3600
        guard !subscribing, !(fresh && defaults.integer(forKey: "subscriptionsVersion") == Self.subscriptionsVersion) else { return }
        subscribing = true
        defer { subscribing = false }
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
            defaults.set(Date().timeIntervalSince1970, forKey: "subscribedAt")
            defaults.set(Self.subscriptionsVersion, forKey: "subscriptionsVersion")
        }
    }
}

/// The sessions, the status and the change token from the last fetch, in Caches: the app opens on them at once.
private struct LinkCache: Codable {
    var sessions: [SessionSnapshot]
    var status: MacStatus?
    var tokenData: Data?

    init(sessions: [SessionSnapshot], status: MacStatus?, token: CKServerChangeToken?) {
        self.sessions = sessions
        self.status = status
        tokenData = token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    var token: CKServerChangeToken? {
        tokenData.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
    }

    private static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("cloud-link.json")
    }

    static func load() -> LinkCache? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LinkCache.self, from: data)
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
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
