import Foundation

/// A button pressed on a phone alert, posted to the secret reply topic as `kind:session:code`.
public struct PhoneAction: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case allow, deny
        case proceed = "continue"
    }

    public var kind: Kind
    public var sessionId: String
    public var code: String

    public init(kind: Kind, sessionId: String, code: String) {
        self.kind = kind
        self.sessionId = sessionId
        self.code = code
    }

    public var body: String { "\(kind.rawValue):\(sessionId):\(code)" }

    public static func parse(_ text: String) -> PhoneAction? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let kind = Kind(rawValue: parts[0]), !parts[1].isEmpty,
              parts[2].count >= 16 else { return nil }
        return PhoneAction(kind: kind, sessionId: parts[1], code: parts[2])
    }
}

/// One-time codes for phone buttons: each alert gets a code that works once, for one session,
/// for the actions it offered, for the exact prompt or state it was sent about (its scope),
/// and only for a limited time. Anything else is ignored.
public struct PhoneCodes: Sendable {
    private struct Grant: Sendable {
        var sessionId: String
        var kinds: Set<PhoneAction.Kind>
        var scope: String
        var expires: Date
    }

    private var grants: [String: Grant] = [:]
    public let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 600) {
        self.lifetime = lifetime
    }

    /// A new code for these buttons on this session's alert. `scope` identifies what the alert was about
    /// (one permission prompt, or one finished state), so the buttons can't act on anything that came later.
    public mutating func issue(sessionId: String, kinds: Set<PhoneAction.Kind>, scope: String, now: Date,
                               random: () -> String = PhoneCodes.randomCode) -> String {
        grants = grants.filter { $0.value.expires > now }
        let code = random()
        grants[code] = Grant(sessionId: sessionId, kinds: kinds, scope: scope, expires: now.addingTimeInterval(lifetime))
        return code
    }

    public enum Redemption: Equatable, Sendable {
        case accepted
        /// A genuine button from an alert whose prompt or state has since moved on (spent, nothing done).
        case outOfDate
        /// Unknown, used, expired or forged: ignore silently.
        case rejected
    }

    /// Accepts a valid, unexpired code once, for its session, an offered action and the session's current
    /// scope. The code is spent either way once it matches; a code whose scope moved on is `outOfDate`.
    public mutating func redeem(_ action: PhoneAction, currentScope: String?, now: Date) -> Redemption {
        guard let grant = grants[action.code], grant.expires > now,
              grant.sessionId == action.sessionId, grant.kinds.contains(action.kind) else { return .rejected }
        grants[action.code] = nil
        return grant.scope == currentScope ? .accepted : .outOfDate
    }

    /// Forgets every code for a session (e.g. its prompt was answered elsewhere).
    public mutating func revoke(sessionId: String) {
        grants = grants.filter { $0.value.sessionId != sessionId }
    }

    /// 128 random bits as 32 hex characters.
    public static func randomCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
