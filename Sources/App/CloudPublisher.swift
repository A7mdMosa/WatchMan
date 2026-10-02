import AppKit
import CloudKit
import Observation
import WatchManCore

/// WatchMan's side of the link to the iPhone: it keeps your private iCloud database up to date with every
/// session (state, waiting prompt, recent chat) and your plan's usage, and carries out what you do on the phone.
/// Writes follow the store's changes (a moment later, a few seconds apart at most). Commands arrive by push, but
/// macOS delays or drops iCloud's silent pushes, so they're also read with each write and, while the phone is in
/// use, every few seconds.
@MainActor @Observable
final class CloudPublisher {
    enum State: Equatable {
        case starting
        case off(String)
        case on(lastSync: Date?)
    }

    private(set) var state: State = .starting

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private var database: CKDatabase { CloudRecords.container.privateCloudDatabase }
    /// What was last written, to write only what changed (`updated` aside).
    @ObservationIgnored private var sentSessions: [String: SessionSnapshot] = [:]
    @ObservationIgnored private var sentChats: [String: Date] = [:]
    @ObservationIgnored private var sentStatus: MacStatus?
    @ObservationIgnored private var sentGlance: Glance?
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var changeToken: CKServerChangeToken?
    @ObservationIgnored private var fetchingCommands = false
    /// When commands were last read, and when the phone last sent one (it's in use: read often).
    @ObservationIgnored private var lastCommandFetch = Date.distantPast
    @ObservationIgnored private var lastPhoneCommand = Date.distantPast
    @ObservationIgnored private var commandPoll: Task<Void, Never>?

    static let minimumGap: TimeInterval = 3
    /// The running one, for Settings to show how the link is doing.
    static var current: CloudPublisher?

    init(store: SessionStore) {
        self.store = store
    }

    /// Checks iCloud, makes the zone and the push subscription for commands, then follows the store.
    func start() async {
        do {
            let account = try await CloudRecords.container.accountStatus()
            guard account == .available else {
                state = .off(account == .noAccount ? "Sign in to iCloud on this Mac to link the iPhone" : "iCloud isn't available")
                return
            }
            _ = try await database.save(CKRecordZone(zoneID: CloudRecords.zoneID))
            try await ensureCommandType()
            let subscription = CKQuerySubscription(recordType: CloudRecords.Kind.command, predicate: NSPredicate(value: true),
                                                   subscriptionID: "watchman-commands", options: [.firesOnRecordCreation])
            subscription.zoneID = CloudRecords.zoneID
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await database.save(subscription)
            NSApp.registerForRemoteNotifications()
            state = .on(lastSync: nil)
            Log.info("cloud link on")
            retryDelay = 60
            follow()
            schedulePublish()
            await fetchCommands()
        } catch {
            state = .off("iCloud: \(error.localizedDescription)")
            Log.info("cloud link off: \(error)")
            retryStart()
        }
    }

    /// iCloud's development schema only knows a record type (and its fields) once one has been saved, and push
    /// subscriptions need their types: save a stale placeholder of each (the command, the alerts), then remove
    /// them. In the default zone: the subscriptions watch WatchMan's zone, so a placeholder there showed on the
    /// iPhone as an empty "WatchMan" alert, four of them each time the Mac app started.
    private func ensureCommandType() async throws {
        func placeholder(_ kind: String) -> CKRecord.ID {
            CKRecord.ID(recordName: "placeholder-" + kind, zoneID: CKRecordZone.ID.default)
        }
        let command = CKRecord(recordType: CloudRecords.Kind.command, recordID: placeholder(CloudRecords.Kind.command))
        command.encryptedValues["data"] = try JSONEncoder().encode(PhoneCommand(sessionId: "", kind: .allow, created: .distantPast))
        let glance = CKRecord(recordType: CloudRecords.Kind.glance, recordID: placeholder(CloudRecords.Kind.glance))
        glance.encryptedValues["data"] = Data()
        var placeholders = [command, glance]
        for kind in CloudRecords.Alert.all {
            let record = CKRecord(recordType: kind, recordID: placeholder(kind))
            record["sessionId"] = ""
            record["title"] = ""
            record["body"] = ""
            record["asked"] = 0.0
            placeholders.append(record)
        }
        _ = try await database.modifyRecords(saving: placeholders, deleting: [], savePolicy: .allKeys)
        _ = try await database.modifyRecords(saving: [], deleting: placeholders.map(\.recordID))
    }

    // MARK: Alerts on the iPhone

    @ObservationIgnored private var sentAlerts: [(id: CKRecord.ID, at: Date)] = []

    var isOn: Bool { if case .on = state { true } else { false } }

    /// A test notification on the iPhone, from Settings → Phone.
    func sendTestAlert() {
        guard isOn else { return }
        let record = CloudRecords.alertRecord(CloudRecords.Alert.note, sessionId: "test",
                                              title: "WatchMan alerts work on this iPhone", body: "")
        sentAlerts.append((record.recordID, Date()))
        Task { _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys) }
    }

    /// A notification on the iPhone for what just happened to a session, with buttons when the phone can answer
    /// it (WatchMan holds the prompt). `title`/`message` override the words (a stuck session).
    func alert(_ session: Session, title: String? = nil, message: String? = nil) {
        guard isOn else { return }
        let name = session.label
        let held = store.hasPendingPrompt(session.id)
        let kind: String
        var heading: String
        var body: String
        if let approval = session.pendingApproval, held, approval.isQuestion {
            kind = CloudRecords.Alert.question
            heading = "\(name) asks"
            // The question; its choices are the alert's buttons (long-press)
            body = approval.title
        } else if let approval = session.pendingApproval, held, approval.isPlan {
            kind = CloudRecords.Alert.plan
            heading = "\(name)'s plan is ready"
            body = approval.title
        } else if let approval = session.pendingApproval, held {
            kind = CloudRecords.Alert.permission
            heading = "\(name) wants to \(approval.kind == .command ? "run" : approval.kind == .other ? "use \(approval.tool)" : "edit")"
            body = approval.command ?? approval.fileName ?? approval.detail
            if approval.isRisky { body = "⚠️ " + body }
        } else {
            // A note is one line: what happened, and at most a few words more
            kind = CloudRecords.Alert.note
            body = ""
            if session.rateLimited {
                heading = "\(name) hit the usage limit" + (session.limitReset.map { " · resets \($0)" } ?? "")
            } else if session.failed {
                heading = "\(name) stopped with an error"
            } else if session.status.isNeedsYou {
                heading = "\(name) needs you"
            } else {
                heading = "\(name) finished"
            }
        }
        if let title {
            heading = title
            // "WatchMan may be stuck · no activity for 10 min"
            if kind == CloudRecords.Alert.note, let message, !message.isEmpty, message.count <= 40 {
                heading += " · " + message.prefix(1).lowercased() + message.dropFirst()
            }
        }
        if let message, kind != CloudRecords.Alert.note { body = message }
        let record = CloudRecords.alertRecord(kind, sessionId: session.id, title: heading, body: body,
                                              asked: kind == CloudRecords.Alert.note ? nil : session.pendingApproval?.requestedAt)
        // Alerts are only for the moment: the ones older than an hour go
        let old = sentAlerts.filter { Date().timeIntervalSince($0.at) > 3600 }.map(\.id)
        sentAlerts.removeAll { Date().timeIntervalSince($0.at) > 3600 }
        sentAlerts.append((record.recordID, Date()))
        Task {
            do {
                _ = try await database.modifyRecords(saving: [record], deleting: old, savePolicy: .allKeys)
            } catch {
                Log.info("iPhone alert failed: \(error)")
            }
        }
    }

    @ObservationIgnored private var retryDelay: TimeInterval = 60

    /// iCloud refused or was unreachable (a new container takes minutes to reach every server, the network may be
    /// down): try again later, waiting longer each time, up to half an hour.
    private func retryStart() {
        let wait = retryDelay
        retryDelay = min(retryDelay * 2, 1800)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            await self?.start()
        }
    }

    // MARK: Publishing

    /// Every change to the sessions or the usage schedules a publish (no polling).
    private func follow() {
        withObservationTracking {
            _ = store.sessions
            _ = store.planUsage
            _ = store.followUps
            _ = store.scheduledContinues
            _ = PhoneControl.shared.extras()
            _ = PhoneControl.shared.chatRequests
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedulePublish()
                self?.follow()
            }
        }
    }

    /// A moment after the last change, and never closer than a few seconds to the previous publish.
    private func schedulePublish() {
        guard case .on = state, publishTask == nil else { return }
        let wait = max(1, Self.minimumGap - Date().timeIntervalSince(lastPublish))
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self else { return }
            self.publishTask = nil
            await self.publish()
        }
    }

    private func publish() async {
        lastPublish = Date()
        let now = Date()
        var saving: [CKRecord] = []
        var current: [String: SessionSnapshot] = [:]
        for session in store.ordered {
            var snapshot = SessionSnapshot(session: session, name: session.label, colorKey: session.colorKey, task: session.task,
                                           held: store.hasPendingPrompt(session.id),
                                           limitReset: session.rateLimited ? store.limitResetDate(for: session) : nil, now: now)
            snapshot.extras = store.phoneExtras(for: session)
            current[session.id] = snapshot
            if let sent = sentSessions[session.id], Self.same(sent, snapshot) { continue }
            if let record = try? CloudRecords.record(CloudRecords.Kind.session, name: session.id, snapshot) { saving.append(record) }
        }
        let gone = Set(sentSessions.keys).subtracting(current.keys)
        let deleting = gone.flatMap { [CloudRecords.id($0), CloudRecords.id(CloudRecords.chatName($0))] }

        let status = MacStatus(macName: Host.current().localizedName ?? "Mac", usage: store.planUsage, updated: now,
                               extras: PhoneControl.shared.extras())
        if sentStatus?.usage != status.usage || sentStatus?.macName != status.macName || sentStatus?.extras != status.extras,
           let record = try? CloudRecords.record(CloudRecords.Kind.status, name: CloudRecords.statusName, status) {
            saving.append(record)
        }
        // The widgets' summary, when what they show changed
        let glance = Glance(sessions: store.ordered.compactMap { current[$0.id] }, usage: store.planUsage,
                            macName: status.macName, updated: now)
        if glance.withoutTimes != sentGlance?.withoutTimes,
           let record = try? CloudRecords.record(CloudRecords.Kind.glance, name: CloudRecords.glanceName, glance) {
            saving.append(record)
        }
        saving += await chatRecords()

        guard !saving.isEmpty || !deleting.isEmpty else { return }
        do {
            _ = try await database.modifyRecords(saving: saving, deleting: deleting, savePolicy: .allKeys, atomically: false)
            // A write is a cheap moment to look for commands a push didn't bring
            if Date().timeIntervalSince(lastCommandFetch) > Self.minimumGap { Task { await fetchCommands() } }
            sentSessions = current
            for id in gone { sentChats[id] = nil }
            sentStatus = status
            sentGlance = glance
            state = .on(lastSync: Date())
            Log.info("cloud published \(saving.count) records, deleted \(deleting.count)")
        } catch {
            Log.info("cloud publish failed: \(error)")
            // Try again on the next change
            sentSessions = [:]
        }
    }

    /// The chats of sessions that changed since they were last sent (the ten most recent, active today), and the
    /// ones the phone asked for (any age, as long as it asked).
    private func chatRecords() async -> [CKRecord] {
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        let control = PhoneControl.shared
        let requested = control.takeChatRequests()
        let changed = store.ordered
            .filter { $0.lastActivity > dayAgo && $0.lastActivity > (sentChats[$0.id] ?? .distantPast) }
            .prefix(10)
        let asked = store.ordered.filter { requested.contains($0.id) && !changed.contains($0) }
        var records: [CKRecord] = []
        for session in Array(changed) + asked {
            guard let path = session.transcriptPath, let transcript = await store.transcriptState(path: path) else { continue }
            let chat = ChatSnapshot(sessionId: session.id, chat: transcript.chat, limit: control.chatLimit(for: session.id))
            if let record = try? CloudRecords.record(CloudRecords.Kind.chat, name: CloudRecords.chatName(session.id), chat) {
                records.append(record)
                sentChats[session.id] = session.lastActivity
            }
        }
        return records
    }

    /// Equal apart from when it was made.
    private static func same(_ a: SessionSnapshot, _ b: SessionSnapshot) -> Bool {
        var b = b
        b.updated = a.updated
        return a == b
    }

    // MARK: Commands from the phone

    /// How often to read commands without waiting for a push: every few seconds while you're using the phone,
    /// less often for half an hour after, then not at all (pushes, wakes and writes only).
    private var pollInterval: TimeInterval? {
        let since = Date().timeIntervalSince(lastPhoneCommand)
        return since < 3 * 60 ? 3 : since < 30 * 60 ? 15 : nil
    }

    private func pollWhilePhoneInUse() {
        guard commandPoll == nil else { return }
        commandPoll = Task { [weak self] in
            while let interval = self?.pollInterval {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(self.lastCommandFetch) >= interval - 0.5 { await self.fetchCommands() }
            }
            self?.commandPoll = nil
        }
    }

    /// Reads new commands (after a push, a wake, or at launch), carries out the fresh ones, deletes them all.
    func fetchCommands() async {
        guard case .on = state, !fetchingCommands else { return }
        fetchingCommands = true
        lastCommandFetch = Date()
        defer { fetchingCommands = false }
        do {
            var done: [CKRecord.ID] = []
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: CloudRecords.zoneID, since: changeToken)
                for (id, result) in changes.modificationResultsByID {
                    guard case .success(let modification) = result, modification.record.recordType == CloudRecords.Kind.command else { continue }
                    if let command = CloudRecords.value(PhoneCommand.self, in: modification.record), !command.isStale() {
                        lastPhoneCommand = Date()
                        pollWhilePhoneInUse()
                        // Photos sent with a reply go in as file paths, the way the Mac's own attachments do
                        store.perform(PhoneControl.withPhotos(command, from: modification.record))
                    }
                    done.append(id)
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
            if !done.isEmpty {
                _ = try await database.modifyRecords(saving: [], deleting: done)
            }
        } catch {
            Log.info("cloud commands failed: \(error)")
            changeToken = nil
        }
    }
}

extension SessionStore {
    /// Carries out what you did on the phone, the same way the notch would.
    func perform(_ command: PhoneCommand) {
        let id = command.sessionId
        // Settings, new sessions, earlier chats and the rest: most aren't about a session
        if case .mac(let request) = command.kind {
            performMac(request, for: id)
            Log.info("phone: \(request)")
            return
        }
        guard let session = sessions[id] else {
            Log.info("phone: dropped \(command.kind) for a session the Mac doesn't have (\(id))")
            return
        }
        // The phone showed a prompt that has since been answered or replaced: never let it answer the next one
        if command.answersAnotherPrompt(than: session.pendingApproval?.requestedAt) {
            Log.info("phone: dropped \(command.kind) for an earlier prompt of \(session.label)")
            return
        }
        switch command.kind {
        case .allow: respond(to: id, with: .allow)
        case .alwaysAllow: respond(to: id, with: .always)
        case .deny(let message): respond(to: id, with: .deny, message: message)
        case .answer(let answers): answerQuestion(id, with: answers)
        case .reply(let text):
            if session.status == .working {
                enqueueFollowUp(text, for: id)
            } else {
                Task { _ = await reply(text, to: id) }
            }
        case .continueAfterLimit: scheduleContinue(id)
        case .pick(let index): _ = pickOption(index, for: id)
        case .mac: break
        }
        Log.info("phone: \(command.kind) for \(session.label)")
    }
}
