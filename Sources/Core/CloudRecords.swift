import CloudKit
import Foundation

/// The link between WatchMan on the Mac and on the iPhone: records in a zone of your private iCloud database.
/// Each record carries one JSON value in an end-to-end encrypted field, so even Apple can't read your chats.
public enum CloudRecords {
    public static let containerID = "iCloud.com.moussa.watchman"
    public static let zoneID = CKRecordZone.ID(zoneName: "WatchMan", ownerName: CKCurrentUserDefaultName)

    /// A session's snapshot (named by session id), its chat ("chat-" + id), the Mac's status ("status"), and a
    /// command from the phone (named by its id).
    public enum Kind {
        public static let session = "Session"
        public static let chat = "Chat"
        public static let status = "Status"
        public static let command = "Command"
        /// The iPhone widgets' summary of every session and the usage (one record, `glanceName`), which they read
        /// by themselves while the app sleeps.
        public static let glance = "Glance"
    }

    /// Notifications for the iPhone, one record type per set of buttons: iCloud turns each new one into a visible
    /// notification with that category's actions. Their few words are plain fields (iCloud has to read them to
    /// show them); everything else stays encrypted.
    public enum Alert {
        public static let permission = "PermissionAlert"   // Allow, Deny
        public static let question = "QuestionAlert"       // your own answer, or open the choices
        public static let plan = "PlanAlert"               // Approve, Keep Planning
        public static let note = "NoteAlert"               // finished, stopped, the limit: no buttons
        public static let all = [permission, question, plan, note]
    }

    /// `asked`: when the prompt came, so a button on the alert answers only that prompt.
    public static func alertRecord(_ kind: String, sessionId: String, title: String, body: String,
                                   asked: Date? = nil) -> CKRecord {
        let record = CKRecord(recordType: kind, recordID: id("alert-" + UUID().uuidString))
        record["sessionId"] = sessionId
        if let asked { record["asked"] = asked.timeIntervalSince1970 }
        record["title"] = String(title.prefix(120))
        record["body"] = String(body.prefix(240))
        return record
    }

    public static var container: CKContainer { CKContainer(identifier: containerID) }

    public static func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
    public static func chatName(_ sessionId: String) -> String { "chat-" + sessionId }
    public static let statusName = "status"
    public static let glanceName = "glance"

    public static func record<T: Encodable>(_ kind: String, name: String, _ value: T) throws -> CKRecord {
        let record = CKRecord(recordType: kind, recordID: id(name))
        record.encryptedValues["data"] = try JSONEncoder().encode(value)
        return record
    }

    public static func value<T: Decodable>(_ type: T.Type, in record: CKRecord) -> T? {
        guard let data = record.encryptedValues["data"] as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// What the Mac says about itself: its name and your plan's usage.
public struct MacStatus: Codable, Equatable, Sendable {
    public var macName: String
    public var usage: PlanUsage?
    public var updated: Date
    /// Its settings and the lists the phone asked for (optional, so older records still read).
    public var extras: MacExtras?

    public init(macName: String, usage: PlanUsage?, updated: Date, extras: MacExtras? = nil) {
        self.macName = macName
        self.usage = usage
        self.updated = updated
        self.extras = extras
    }
}
