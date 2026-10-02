import XCTest
@testable import WatchManCore

final class HostKindTests: XCTestCase {
    func testDetectsTerminals() {
        XCTAssertEqual(HostKind.detect(environment: ["TERM_PROGRAM": "ghostty"]), .ghostty)
        XCTAssertEqual(HostKind.detect(environment: ["GHOSTTY_RESOURCES_DIR": "/x"]), .ghostty)
        XCTAssertEqual(HostKind.detect(environment: ["TERM_PROGRAM": "iTerm.app"]), .iterm)
        XCTAssertEqual(HostKind.detect(environment: ["TERM_PROGRAM": "Apple_Terminal"]), .terminal)
        XCTAssertEqual(HostKind.detect(environment: ["TERM_PROGRAM": "vscode"]), .vscodeTerminal)
        XCTAssertEqual(HostKind.detect(environment: ["__CFBundleIdentifier": "com.microsoft.VSCode"]), .vscodeExtension)
        XCTAssertEqual(HostKind.detect(environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode", "TERM_PROGRAM": "vscode"]), .vscodeExtension)
        XCTAssertEqual(HostKind.detect(environment: [:]), .other)
    }

    func testOnlyScriptableTerminalsCanSend() {
        XCTAssertTrue(HostKind.ghostty.canSend)
        XCTAssertTrue(HostKind.iterm.canSend)
        XCTAssertFalse(HostKind.vscodeExtension.canSend)
    }
}

final class HookEventTests: XCTestCase {
    func testParsesRelayedPayload() throws {
        let json = """
        {"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/Users/me","transcript_path":"/t.jsonl",
         "tool_name":"Bash","tool_input":{"command":"ls","timeout":5},"wm_host":"ghostty","wm_tty":"/dev/ttys003","wm_pid":42}
        """
        let event = try XCTUnwrap(HookEvent.parse(Data(json.utf8)))
        XCTAssertEqual(event.name, "PreToolUse")
        XCTAssertEqual(event.host, .ghostty)
        XCTAssertEqual(event.tty, "/dev/ttys003")
        XCTAssertEqual(event.claudePid, 42)
        XCTAssertEqual(event.toolInput, ["command": "ls"])
    }

    func testRejectsPayloadWithoutSession() {
        XCTAssertNil(HookEvent.parse(Data(#"{"hook_event_name":"Stop"}"#.utf8)))
    }
}

final class PermissionReplyTests: XCTestCase {
    private func decision(_ output: String?) throws -> [String: Any] {
        let data = Data(try XCTUnwrap(output).utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        return try XCTUnwrap(specific["decision"] as? [String: Any])
    }

    func testAllowDenyAlways() throws {
        XCTAssertEqual(try decision(PermissionDecision.allow.hookOutput(permissionSuggestions: nil))["behavior"] as? String, "allow")
        XCTAssertEqual(try decision(PermissionDecision.deny.hookOutput(permissionSuggestions: nil))["behavior"] as? String, "deny")
        let always = try decision(PermissionDecision.always.hookOutput(permissionSuggestions: [["type": "addRules"]]))
        XCTAssertEqual((always["updatedPermissions"] as? [Any])?.count, 1)
        XCTAssertNil(PermissionDecision.ask.hookOutput(permissionSuggestions: nil))
    }

    func testSocketRoundTrip() {
        let line = PermissionDecision.always.socketLine
        XCTAssertEqual(PermissionDecision.parse(socketLine: Data(line.utf8.dropLast())), .always)
        XCTAssertEqual(PermissionDecision.parse(socketLine: Data("junk".utf8)), .ask)
    }
}

final class SessionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLifecycle() {
        var session = Session(id: "s", cwd: "/Users/me", host: .other, now: t0)
        session.apply(HookEvent(name: "SessionStart", sessionId: "s", host: .ghostty, tty: "/dev/ttys001"), now: t0)
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.host, .ghostty)

        session.apply(HookEvent(name: "UserPromptSubmit", sessionId: "s"), now: t0 + 1)
        XCTAssertEqual(session.status, .working)

        session.apply(HookEvent(name: "PermissionRequest", sessionId: "s", toolName: "Bash",
                                toolInput: ["command": "rm -rf build"]), now: t0 + 2)
        XCTAssertTrue(session.status.isNeedsYou)
        XCTAssertEqual(session.pendingApproval?.detail, "Run · rm -rf build")
        XCTAssertEqual(session.statusSince, t0 + 2)

        session.apply(HookEvent(name: "PostToolUse", sessionId: "s"), now: t0 + 3)
        XCTAssertEqual(session.status, .working)
        XCTAssertNil(session.pendingApproval)

        session.apply(HookEvent(name: "Stop", sessionId: "s"), now: t0 + 4)
        XCTAssertEqual(session.status, .finished)
        XCTAssertTrue(session.isUnseenResult)

        // The idle reminder doesn't turn a finished session into a question
        session.apply(HookEvent(name: "Notification", sessionId: "s", message: "Claude is waiting for your input"), now: t0 + 60)
        XCTAssertEqual(session.status, .finished)

        session.apply(HookEvent(name: "UserPromptSubmit", sessionId: "s"), now: t0 + 65)
        XCTAssertTrue(session.seen)

        session.apply(HookEvent(name: "SessionEnd", sessionId: "s"), now: t0 + 70)
        XCTAssertEqual(session.status, .closed)
    }

    func testStepLabels() {
        XCTAssertEqual(Session.stepLabel(tool: "Edit", input: ["file_path": "/a/b/main.dart"]), "Edit · main.dart")
        XCTAssertEqual(Session.stepLabel(tool: "Bash", input: ["command": "flutter test", "description": "Run tests"]), "Run · Run tests")
        XCTAssertEqual(Session.stepLabel(tool: "mcp__obsidian-vault__read_file", input: [:]), "obsidian-vault · read_file")
        XCTAssertEqual(Session.stepLabel(tool: "TodoWrite", input: [:]), "Update tasks")
    }

    func testSortPutsLongestWaitingFirst() {
        func make(_ id: String, _ status: SessionStatus, since: TimeInterval, activity: TimeInterval) -> Session {
            var s = Session(id: id, cwd: "/", host: .ghostty, now: t0)
            s.status = status
            s.statusSince = t0 + since
            s.lastActivity = t0 + activity
            return s
        }
        let sorted = Session.sortedForDisplay([
            make("idle", .idle, since: 0, activity: 50),
            make("work", .working, since: 0, activity: 40),
            make("newWait", .needsYou("q"), since: 30, activity: 30),
            make("oldWait", .needsYou("q"), since: 10, activity: 10),
            make("gone", .closed, since: 0, activity: 99),
            make("done", .finished, since: 0, activity: 20),
            { var s = make("new", .finished, since: 0, activity: 5); s.seen = false; return s }(),
        ]).map(\.id)
        XCTAssertEqual(sorted, ["oldWait", "newWait", "new", "work", "done", "idle"])
    }

    func testSameProjectSessionsSitTogether() {
        func working(_ id: String, _ root: String, activity: TimeInterval) -> Session {
            var s = Session(id: id, cwd: root, host: .ghostty, now: t0)
            s.status = .working
            s.lastActivity = t0 + activity
            return s
        }
        let sorted = Session.sortedForDisplay([working("a1", "/p/alpha", activity: 30), working("b1", "/p/beta", activity: 20),
                                               working("a2", "/p/alpha", activity: 10)]).map(\.id)
        XCTAssertEqual(sorted, ["a1", "a2", "b1"])
    }
}

final class TranscriptTests: XCTestCase {
    func testReadsFixture() throws {
        let url = try XCTUnwrap(Bundle(for: TranscriptTests.self).url(forResource: "transcript", withExtension: "jsonl",
                                                                      subdirectory: "Fixtures"))
        var state = TranscriptState()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            state.consume(line: Data(line.utf8))
        }
        XCTAssertEqual(state.title, "Login bug fix")
        XCTAssertEqual(state.lastReply, "Login fixed. One test fails: token expiry.")
        XCTAssertEqual(state.entrypoint, "cli")
        XCTAssertEqual(state.verification.analyze?.result, .passed)
        XCTAssertEqual(state.verification.test?.result, .failed)
        XCTAssertEqual(state.editedFiles, ["/Users/me/Developer/app/lib/login.dart"])
        XCTAssertTrue(state.editedAfterSync)
        XCTAssertEqual(state.lastPrompt, "fix the login bug")
        // msg_2 appears twice but is counted once; the sidechain message isn't counted
        XCTAssertEqual(state.usage.map(\.tokens), [150, 15, 15, 30])
    }

    func testOnlyRealAnalyzeCommandsCount() {
        XCTAssertEqual(TranscriptState.check(for: "flutter analyze"), .analyze)
        XCTAssertEqual(TranscriptState.check(for: "cd app && flutter analyze lib"), .analyze)
        XCTAssertEqual(TranscriptState.check(for: "fvm flutter test --reporter compact"), .test)
        XCTAssertEqual(TranscriptState.check(for: "dart analyze; echo done"), .analyze)
        XCTAssertNil(TranscriptState.check(for: "echo 'run flutter analyze and flutter test' > replies.txt"))
        XCTAssertNil(TranscriptState.check(for: "python3 - <<'PY'\nflutter analyze\nPY"))
        XCTAssertNil(TranscriptState.check(for: "grep -rn \"flutter test\" docs/"))
    }

    func testContinuedSessionIsHidden() {
        var state = TranscriptState()
        state.consume(["type": "continued-in", "sessionId": "parent", "continuedInSessionId": "child"])
        XCTAssertEqual(state.continuedIn, "child")

        let now = Date()
        var parent = Session(id: "parent", cwd: "/", host: .ghostty, now: now)
        parent.continuedIn = state.continuedIn
        let child = Session(id: "child", cwd: "/", host: .ghostty, now: now)
        XCTAssertEqual(Session.sortedForDisplay([parent, child]).map(\.id), ["child"])
    }

    func testRenamedTitleWinsOverLaterAutomaticTitles() {
        var state = TranscriptState()
        state.consume(["type": "ai-title", "aiTitle": "Build approach clarification"])
        state.consume(["type": "custom-title", "customTitle": "WatchMan"])
        state.consume(["type": "ai-title", "aiTitle": "Build approach clarification"])
        XCTAssertEqual(state.title, "WatchMan")
    }

    func testProjectSyncClearsFlag() {
        var state = TranscriptState()
        state.consume(["type": "assistant", "timestamp": "2026-10-01T08:00:00.000Z",
                       "message": ["content": [["type": "tool_use", "id": "x", "name": "Write",
                                                "input": ["file_path": "/p/a.swift"]]]]])
        XCTAssertTrue(state.editedAfterSync)
        state.consume(["type": "user", "timestamp": "2026-10-01T08:05:00.000Z",
                       "message": ["content": "/project-sync"]])
        XCTAssertFalse(state.editedAfterSync)
    }

    func testProjectRootIsGitRootOfLatestEdit() {
        let roots: Set<String> = ["/Users/me/Developer/app", "/Users/me/Developer/web"]
        let root = ProjectLocator.projectRoot(editedFiles: ["/Users/me/Developer/web/src/a.ts", "/Users/me/Developer/app/lib/b.dart"],
                                              cwd: "/Users/me", isGitRoot: roots.contains)
        XCTAssertEqual(root, "/Users/me/Developer/app")
    }
}

final class UsageTests: XCTestCase {
    func testFiveHourBlocks() {
        let base = TranscriptState.parseDate("2026-10-01T08:20:00.000Z")!
        let entries: [TranscriptState.UsageEntry] = [
            .init(at: base, tokens: 100),                         // block 08:00–13:00
            .init(at: base + 3600, tokens: 50),
            .init(at: base + 6 * 3600, tokens: 7),                // 14:20 → new block 14:00–19:00
            .init(at: base + 6.5 * 3600, tokens: 3),
        ]
        let summary = UsageSummary.compute(entries: entries, now: base + 7 * 3600)
        XCTAssertEqual(summary.currentBlockTokens, 10)
        XCTAssertEqual(summary.currentBlockStart, TranscriptState.parseDate("2026-10-01T14:00:00.000Z"))
        XCTAssertEqual(summary.lastSevenDaysTokens, 160)

        let idle = UsageSummary.compute(entries: entries, now: base + 20 * 3600)
        XCTAssertEqual(idle.currentBlockTokens, 0)
        XCTAssertNil(idle.currentBlockStart)
    }

    func testFormat() {
        XCTAssertEqual(UsageSummary.format(1_250_000), "1.2M")
        XCTAssertEqual(UsageSummary.format(85_300), "85K")
        XCTAssertEqual(UsageSummary.format(900), "900")
    }
}

final class ProcessTableTests: XCTestCase {
    let sample = """
      100     1  50000 ttys001 Ss+  /Users/me/.local/share/claude/versions/2.1.2/claude
      101   100  20000 ttys001 S+   node mcp-server.js
      102   101  10000 ttys001 S+   dart analysis_server
      200     1  30000 ttys002 Ss   -zsh
      300     1 900000 ??      S    /usr/bin/java -cp gradle.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.7
      400     1 120000 ??      S    dart analysis_server.dart.snapshot --lsp
      500     1  40000 ttys003 S+   claude --dangerously-skip-permissions
    """

    func testTreeAndForeground() {
        let table = ProcessTable.parse(sample)
        XCTAssertEqual(table.entries.count, 7)
        XCTAssertEqual(table.treeRSSKB(of: 100), 80000)
        XCTAssertTrue(table.claudeIsForeground(onTTY: "/dev/ttys001"))
        XCTAssertTrue(table.claudeIsForeground(onTTY: "/dev/ttys003"))
        XCTAssertFalse(table.claudeIsForeground(onTTY: "/dev/ttys002"))
    }

    func testStrays() {
        let kinds = ProcessTable.parse(sample).strays().map(\.kind)
        XCTAssertEqual(kinds, ["Gradle daemon", "Dart analyzer (orphan)"])
    }
}

final class RulesTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testFollowUpOnlyAfterCleanFinish() {
        XCTAssertTrue(FollowUpRule.shouldSend(afterEvent: "Stop", status: .finished, hasPendingPrompt: false, canSend: true))
        XCTAssertFalse(FollowUpRule.shouldSend(afterEvent: "StopFailure", status: .needsYou("x"), hasPendingPrompt: false, canSend: true))
        XCTAssertFalse(FollowUpRule.shouldSend(afterEvent: "Stop", status: .finished, hasPendingPrompt: true, canSend: true))
        XCTAssertFalse(FollowUpRule.shouldSend(afterEvent: "Stop", status: .finished, hasPendingPrompt: false, canSend: false))
        XCTAssertFalse(FollowUpRule.shouldSend(afterEvent: "PreToolUse", status: .working, hasPendingPrompt: false, canSend: true))
    }

    func testStuckDetection() {
        var s = Session(id: "s", cwd: "/", host: .ghostty, now: t0)
        s.apply(HookEvent(name: "UserPromptSubmit", sessionId: "s"), now: t0)
        let thresholds = StuckThresholds(noActivityMinutes: 10, repeatCount: 3, longRunMinutes: 45)
        XCTAssertNil(StuckDetector.check(s, now: t0 + 60, thresholds: thresholds))
        XCTAssertEqual(StuckDetector.check(s, now: t0 + 11 * 60, thresholds: thresholds), .noActivity(minutes: 11))

        for i in 0..<3 {
            s.apply(HookEvent(name: "PostToolUseFailure", sessionId: "s", toolName: "Bash",
                              toolInput: ["command": "flutter build apk"]), now: t0 + Double(i))
        }
        XCTAssertEqual(StuckDetector.check(s, now: t0 + 5, thresholds: thresholds), .repeatingFailure("Run · flutter build apk"))
        s.apply(HookEvent(name: "PostToolUse", sessionId: "s"), now: t0 + 6)
        XCTAssertNil(StuckDetector.check(s, now: t0 + 7, thresholds: thresholds))

        // Busy the whole time, just long
        for minute in stride(from: 0.0, through: 50, by: 5) {
            s.apply(HookEvent(name: "PreToolUse", sessionId: "s", toolName: "Read"), now: t0 + minute * 60)
        }
        XCTAssertEqual(StuckDetector.check(s, now: t0 + 50 * 60, thresholds: thresholds), .longRun(minutes: 50))
        XCTAssertTrue(StuckReason.longRun(minutes: 50).sameKind(as: .longRun(minutes: 60)))
    }

    func testProjectKind() {
        XCTAssertEqual(ProjectKind.detect(root: "/a", fileExists: { $0 == "/a/pubspec.yaml" }), .flutter)
        XCTAssertEqual(ProjectKind.detect(root: "/b", fileExists: { $0 == "/b/package.json" }), .web)
        XCTAssertEqual(ProjectKind.detect(root: "/c", fileExists: { _ in false }), .other)
        XCTAssertTrue(ProjectKind.flutter.defaultQuickReplies!.contains("run flutter analyze and flutter test"))
    }

    func testTimeline() throws {
        let url = try XCTUnwrap(Bundle(for: RulesTests.self).url(forResource: "transcript", withExtension: "jsonl",
                                                                  subdirectory: "Fixtures"))
        var state = TranscriptState()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            state.consume(line: Data(line.utf8))
        }
        XCTAssertEqual(state.timeline.map(\.kind), [.prompt, .tool, .tool, .passed, .tool, .failed, .reply])
        XCTAssertEqual(state.timeline.first?.text, "fix the login bug")
        XCTAssertEqual(state.timeline[1].text, "Edit · login.dart")
        XCTAssertEqual(state.conversation.map(\.fromYou), [true, false])
        XCTAssertEqual(state.conversation.first?.text, "fix the login bug")
        // The chat: the prompt, the steps between, then the reply
        let chat = state.chat
        XCTAssertEqual(chat.count, 3)
        guard case .message(let prompt) = chat[0], case .steps(let steps) = chat[1], case .message(let reply) = chat[2] else {
            return XCTFail("chat is \(chat)")
        }
        XCTAssertTrue(prompt.fromYou)
        XCTAssertEqual(steps.map(\.kind), [.tool, .tool, .passed, .tool, .failed])
        XCTAssertFalse(reply.fromYou)
        XCTAssertEqual(TranscriptState.promptText("<command-name>/project-sync</command-name>"), "/project-sync")
        XCTAssertNil(TranscriptState.promptText("<system-reminder>x</system-reminder>"))
    }
}

final class ObsidianTests: XCTestCase {
    func testTodosParsedWithDueDates() {
        let note = """
        ## To do
        - [ ] Upload on Google Play  [due:: 2026-10-02]
        - [x] Done already
        - [ ] Fixing the UI
          - [ ] Deploy to App Store 📅 2026-10-01 [priority:: high]
        - [ ]
        """
        let todos = ObsidianTodos.parse(note)
        XCTAssertEqual(todos.map(\.text), ["Upload on Google Play", "Fixing the UI", "Deploy to App Store"])
        XCTAssertEqual(todos[0].due, ObsidianTodos.day("2026-10-02"))
        XCTAssertNil(todos[1].due)
        XCTAssertEqual(ObsidianTodos.sorted(todos).map(\.text), ["Deploy to App Store", "Upload on Google Play", "Fixing the UI"])
    }

    func testProjectSyncTodos() {
        let note = #"await dv.view("04 Templates/Views/dev-card", { data: "05 Assets/Project Sync/CareerPath.json" })"#
        XCTAssertEqual(ObsidianTodos.projectSyncDataPath(inNote: note), "05 Assets/Project Sync/CareerPath.json")
        XCTAssertNil(ObsidianTodos.projectSyncDataPath(inNote: "no card here"))
        let json = #"{"todos": [{"text": "Fix login", "done": false}, {"text": "Ship", "done": true}, {"text": "Write report", "done": false}]}"#
        let todos = ObsidianTodos.parseProjectSync(Data(json.utf8))
        XCTAssertEqual(todos.map(\.text), ["Fix login", "Write report"])
        let merged = ObsidianTodos.merged([TodoItem(text: "fix login", due: nil)], todos)
        XCTAssertEqual(merged.map(\.text), ["fix login", "Write report"])
    }

    func testDigestMarkdown() {
        let md = DigestBuilder.markdown(day: "2026-10-01", projects: [
            DigestProject(name: "Trailmap", sessions: [
                DigestSession(title: "Workout screen", prompts: ["fix the timer", "run tests"],
                              summary: "Fixed the workout timer and added two tests.", filesEdited: 3, tokens: 120_000),
            ], commits: ["Fix workout timer"]),
        ])
        XCTAssertTrue(md.hasPrefix("---\ntype: devlog\ndate: 2026-10-01\njournal: \"[[2026-10-01]]\""))
        XCTAssertTrue(md.contains("projects: [\"Trailmap\"]"))
        XCTAssertTrue(md.contains("## Trailmap"))
        XCTAssertTrue(md.contains("- **Workout screen** · 3 files edited"))
        XCTAssertTrue(md.contains("  - Fixed the workout timer and added two tests."))
        XCTAssertTrue(md.contains("  - Asked: \"fix the timer\", \"run tests\""))
        XCTAssertTrue(md.contains("- Fix workout timer"))
        XCTAssertTrue(DigestBuilder.markdown(day: "2026-10-01", projects: []).contains("No Claude Code sessions today."))
    }
}

final class PhoneActionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 3_000_000)

    func testParse() {
        let action = PhoneAction(kind: .allow, sessionId: "abc-123", code: String(repeating: "f", count: 32))
        XCTAssertEqual(PhoneAction.parse(action.body), action)
        XCTAssertEqual(PhoneAction.parse("continue:s:" + String(repeating: "a", count: 32))?.kind, .proceed)
        XCTAssertNil(PhoneAction.parse("rm:s:" + String(repeating: "a", count: 32)))
        XCTAssertNil(PhoneAction.parse("allow:s:short"))
        XCTAssertNil(PhoneAction.parse("allow::" + String(repeating: "a", count: 32)))
        XCTAssertNil(PhoneAction.parse("hello"))
    }

    func testCodesWorkOnceForTheirSessionAndActions() {
        var codes = PhoneCodes(lifetime: 600)
        let code = codes.issue(sessionId: "s1", kinds: [.allow, .deny], scope: "prompt-A", now: t0)
        XCTAssertEqual(code.count, 32)
        // Wrong session, wrong action: refused, and the code stays usable
        XCTAssertNotEqual(codes.redeem(PhoneAction(kind: .allow, sessionId: "s2", code: code), currentScope: "prompt-A", now: t0), .accepted)
        XCTAssertNotEqual(codes.redeem(PhoneAction(kind: .proceed, sessionId: "s1", code: code), currentScope: "prompt-A", now: t0), .accepted)
        XCTAssertEqual(codes.redeem(PhoneAction(kind: .allow, sessionId: "s1", code: code), currentScope: "prompt-A", now: t0 + 10), .accepted)
        // Spent: a replay is silently rejected
        XCTAssertEqual(codes.redeem(PhoneAction(kind: .deny, sessionId: "s1", code: code), currentScope: "prompt-A", now: t0 + 11), .rejected)
        // Unknown code
        XCTAssertEqual(codes.redeem(PhoneAction(kind: .allow, sessionId: "s1", code: PhoneCodes.randomCode()),
                                    currentScope: "prompt-A", now: t0), .rejected)
    }

    func testOldAlertCantApproveALaterPrompt() {
        var codes = PhoneCodes(lifetime: 600)
        let first = codes.issue(sessionId: "s1", kinds: [.allow, .deny], scope: "prompt-A", now: t0)
        // Prompt A was replaced by prompt B: A's Allow must not approve B, and is spent
        XCTAssertEqual(codes.redeem(PhoneAction(kind: .allow, sessionId: "s1", code: first), currentScope: "prompt-B", now: t0 + 5), .outOfDate)
        XCTAssertNotEqual(codes.redeem(PhoneAction(kind: .allow, sessionId: "s1", code: first), currentScope: "prompt-A", now: t0 + 6), .accepted)
        // Nothing pending any more: refused
        let second = codes.issue(sessionId: "s1", kinds: [.allow], scope: "prompt-B", now: t0)
        XCTAssertNotEqual(codes.redeem(PhoneAction(kind: .allow, sessionId: "s1", code: second), currentScope: nil, now: t0 + 7), .accepted)
        // Revoked codes are gone
        let third = codes.issue(sessionId: "s1", kinds: [.deny], scope: "prompt-C", now: t0)
        codes.revoke(sessionId: "s1")
        XCTAssertNotEqual(codes.redeem(PhoneAction(kind: .deny, sessionId: "s1", code: third), currentScope: "prompt-C", now: t0 + 8), .accepted)
    }

    func testCodesExpire() {
        var codes = PhoneCodes(lifetime: 600)
        let code = codes.issue(sessionId: "s1", kinds: [.proceed], scope: "finished-1", now: t0)
        XCTAssertNotEqual(codes.redeem(PhoneAction(kind: .proceed, sessionId: "s1", code: code), currentScope: "finished-1", now: t0 + 601), .accepted)
        let fresh = codes.issue(sessionId: "s1", kinds: [.proceed], scope: "finished-1", now: t0)
        XCTAssertEqual(codes.redeem(PhoneAction(kind: .proceed, sessionId: "s1", code: fresh), currentScope: "finished-1", now: t0 + 599), .accepted)
    }
}

final class RepliesTests: XCTestCase {
    func testYesNoQuestion() throws {
        let reply = "Both are fixed and pushed.\n\nWant me to commit now?"
        let found = try XCTUnwrap(ClosingQuestion.find(in: reply))
        XCTAssertEqual(found.question, "Want me to commit now?")
        XCTAssertEqual(found.answers.map(\.label), ["Yes", "No"])
        XCTAssertEqual(found.answers.first?.text, "yes, go ahead")
    }

    func testNumberedOptions() throws {
        let reply = """
        Here are the options:
        1. **Fix all 9** — recommended
        2. Only phone security (1–3)
        3) Let me pick

        Which should I do?
        """
        let found = try XCTUnwrap(ClosingQuestion.find(in: reply))
        XCTAssertEqual(found.answers.map(\.text), ["Fix all 9", "Only phone security (1–3)", "Let me pick"])
        XCTAssertEqual(found.answers.first?.label, "1 · Fix all 9")
    }

    func testOpenQuestionHasNoButtonsAndStatementsAreIgnored() {
        XCTAssertEqual(ClosingQuestion.find(in: "Which colour do you prefer, blue or green?")?.answers, [])
        XCTAssertNil(ClosingQuestion.find(in: "Done. Everything is installed."))
        let old = "Is this right?\n" + Array(repeating: "More text here.", count: 12).joined(separator: "\n")
        XCTAssertNil(ClosingQuestion.find(in: old), "a question far from the end isn't the closing question")
    }

    func testLastTurnSummary() {
        var state = TranscriptState()
        state.consume(["type": "user", "timestamp": "2026-10-01T08:00:00.000Z", "message": ["content": "first task"]])
        state.consume(["type": "assistant", "timestamp": "2026-10-01T08:00:01.000Z", "message": ["id": "a",
            "content": [["type": "tool_use", "id": "1", "name": "Edit", "input": ["file_path": "/p/old.swift"]]],
            "usage": ["input_tokens": 5, "output_tokens": 5]]])
        state.consume(["type": "user", "timestamp": "2026-10-01T09:00:00.000Z", "message": ["content": "fix the bug and commit"]])
        state.consume(["type": "assistant", "timestamp": "2026-10-01T09:00:01.000Z", "message": ["id": "b",
            "content": [["type": "tool_use", "id": "2", "name": "Edit", "input": ["file_path": "/p/a.swift"]],
                        ["type": "tool_use", "id": "3", "name": "Write", "input": ["file_path": "/p/b.swift"]],
                        ["type": "tool_use", "id": "4", "name": "Bash", "input": ["command": "git add -A && git commit -m x"]],
                        ["type": "tool_use", "id": "5", "name": "Bash", "input": ["command": "echo 'git commit' > notes.txt"]]],
            "usage": ["input_tokens": 100, "output_tokens": 50]]])
        XCTAssertEqual(state.lastTurn.prompt, "fix the bug and commit")
        XCTAssertEqual(state.lastTurn.filesEdited, ["/p/a.swift", "/p/b.swift"])
        XCTAssertEqual(state.lastTurn.commits, 1)
        XCTAssertEqual(state.lastTurn.tokens, 150)
    }

    func testRegistryIdleKeepsFinishedResult() {
        let t0 = Date(timeIntervalSince1970: 4_000_000)
        var session = Session(id: "s", cwd: "/", host: .ghostty, now: t0)
        session.apply(HookEvent(name: "UserPromptSubmit", sessionId: "s"), now: t0)
        session.apply(HookEvent(name: "Stop", sessionId: "s"), now: t0 + 1)
        session.apply(RegistryEntry(pid: 1, sessionId: "s", cwd: "/", name: nil, status: "idle", entrypoint: "cli",
                                    updatedAt: t0 + 2), host: .ghostty, tty: nil, transcriptPath: nil, now: t0 + 3)
        XCTAssertEqual(session.status, .finished)
        XCTAssertTrue(session.isUnseenResult)
    }

    func testSwiftProjects() {
        XCTAssertEqual(ProjectKind.detect(root: "/w", fileExists: { $0 == "/w/project.yml" }), .swift)
        XCTAssertFalse(ProjectKind.swift.defaultQuickReplies!.contains { $0.contains("flutter") })
    }
}

final class RegistryTests: XCTestCase {
    func testParsesRegistryFile() throws {
        let json = #"{"pid":27859,"sessionId":"ce53","cwd":"/Users/me","name":"Login fix","status":"busy","entrypoint":"cli","statusUpdatedAt":1790808121907}"#
        let entry = try XCTUnwrap(RegistryEntry.parse(Data(json.utf8)))
        XCTAssertEqual(entry.pid, 27859)
        XCTAssertEqual(entry.name, "Login fix")
        XCTAssertEqual(entry.sessionStatus, .working)
        XCTAssertEqual(entry.updatedAt, Date(timeIntervalSince1970: 1790808121.907))
        XCTAssertNil(RegistryEntry.parse(Data(#"{"pid":1}"#.utf8)))
    }

    func testEnvironmentFromPsLine() {
        let line = "27859 claude --resume x TERM=xterm-ghostty TERM_PROGRAM=ghostty __CFBundleIdentifier=com.mitchellh.ghostty HOME=/Users/me"
        let env = HostKind.environment(fromProcessListing: line)
        XCTAssertEqual(env["TERM_PROGRAM"], "ghostty")
        XCTAssertEqual(HostKind.detect(environment: env), .ghostty)
        XCTAssertEqual(HostKind.detect(environment: HostKind.environment(fromProcessListing: "1 claude TERM_PROGRAM=vscode")), .vscodeTerminal)
    }

    func testDiscoveredSessionAndDormancy() {
        let then = Date(timeIntervalSince1970: 1_000_000)
        var entry = RegistryEntry(pid: 5, sessionId: "s", cwd: "/p", name: "Trailmap", status: "idle", entrypoint: "cli", updatedAt: then)
        var session = Session(id: "s", cwd: "", host: .other, now: then)
        session.apply(entry, host: .ghostty, tty: "/dev/ttys002", transcriptPath: "/t.jsonl", now: then + 10)
        XCTAssertEqual(session.title, "Trailmap")
        XCTAssertEqual(session.host, .ghostty)
        XCTAssertEqual(session.status, .idle)
        XCTAssertTrue(session.isDormant(now: then + 7200))
        XCTAssertFalse(session.isDormant(now: then + 600))

        entry.status = "busy"
        entry.updatedAt = then + 20
        session.apply(entry, host: .ghostty, tty: nil, transcriptPath: nil, now: then + 30)
        XCTAssertEqual(session.status, .working)
        XCTAssertFalse(session.isDormant(now: then + 7200))

        var vscode = Session(id: "v", cwd: "", host: .other, now: then)
        vscode.apply(RegistryEntry(pid: 6, sessionId: "v", cwd: "/p", name: nil, status: "waiting", entrypoint: "claude-vscode",
                                   updatedAt: then), host: .other, tty: nil, transcriptPath: nil, now: then)
        XCTAssertEqual(vscode.host, .vscodeExtension)
        XCTAssertTrue(vscode.status.isNeedsYou)
    }
}

final class InstallHooksTests: XCTestCase {
    private var script: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/install-hooks.py").path
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script] + arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testInstallKeepsOtherHooksAndIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        let original = """
        {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/usr/bin/python3 sync.py"}]}]}}
        """
        try original.write(to: settings, atomically: true, encoding: .utf8)

        let hook = "/Users/me/Library/Application Support/WatchMan/watchman-hook"
        try run(["--hook", hook, "--settings", settings.path])
        try run(["--hook", hook, "--settings", settings.path])

        let text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertFalse(text.contains("\\/"), "slashes must not be escaped")
        XCTAssertTrue(text.hasPrefix("{\n  \"model\""), "key order kept")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks.count, 12)
        XCTAssertEqual(hooks["Stop"]?.count, 2, "other Stop hook kept, WatchMan added once")
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-watchman-") }
        XCTAssertFalse(backups.isEmpty)

        try run(["--hook", hook, "--settings", settings.path, "--remove"])
        let removed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let left = try XCTUnwrap(removed["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Array(left.keys), ["Stop"])
        XCTAssertEqual(left["Stop"]?.count, 1)
    }
}

final class NotchActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ id: String, _ status: SessionStatus, since: TimeInterval = 60, step: String? = nil,
                         seen: Bool = true) -> Session {
        var s = Session(id: id, cwd: "/p/\(id)", host: .ghostty, now: now)
        s.title = id.capitalized
        s.status = status
        s.statusSince = now.addingTimeInterval(-since)
        s.lastStep = step
        s.seen = seen
        return s
    }

    func testPriorityFeedbackThenNeedsYouThenFreshThenWorking() {
        let working = session("trailmap", .working, step: "Edit · main.dart")
        let waiting = session("lumen", .needsYou("Permission"))
        let fresh = session("shipyard", .finished, since: 3, seen: false)
        let all = Session.sortedForDisplay([working, waiting, fresh])
        let feedback = NotchActivity.feedback("trailmap", name: "Trailmap", verb: "Sent")

        XCTAssertEqual(NotchActivity.pick(all, feedback: feedback, now: now, rotation: 0), feedback)
        XCTAssertEqual(NotchActivity.pick(all, feedback: nil, now: now, rotation: 0)?.text, "Lumen needs you")
        let noWaiting = Session.sortedForDisplay([working, fresh])
        XCTAssertEqual(NotchActivity.pick(noWaiting, feedback: nil, now: now, rotation: 0)?.text, "Shipyard finished")
        XCTAssertEqual(NotchActivity.pick([working], feedback: nil, now: now, rotation: 0)?.text, "Trailmap · Edit main.dart")
        XCTAssertNil(NotchActivity.pick([session("idle", .idle)], feedback: nil, now: now, rotation: 0))
    }

    func testFreshResultExpiresAfterTenSeconds() {
        let fresh = session("shipyard", .finished, since: 3, seen: false)
        let activity = NotchActivity.pick([fresh], feedback: nil, now: now, rotation: 0)
        XCTAssertEqual(activity?.kind, .finished)
        XCTAssertEqual(NotchActivity.expiry(of: activity, in: [fresh]), now.addingTimeInterval(7))
        let old = session("shipyard", .finished, since: 11, seen: false)
        XCTAssertNil(NotchActivity.pick([old], feedback: nil, now: now, rotation: 0), "an older new result is only counted on the right")
        let seen = session("shipyard", .finished, since: 3, seen: true)
        XCTAssertNil(NotchActivity.pick([seen], feedback: nil, now: now, rotation: 0))
    }

    func testRotationCyclesWorkingSessionsInStartOrder() {
        let first = session("b", .working, since: 300, step: "Read · a.swift")
        let second = session("a", .working, since: 100, step: "Bash · ls")
        let names = (0..<4).map { NotchActivity.pick([second, first], feedback: nil, now: now, rotation: $0)?.name }
        XCTAssertEqual(names, ["B", "A", "B", "A"])
    }

    func testLongStepIsShortened() {
        let busy = session("m", .working, step: "Edit · " + String(repeating: "x", count: 60) + ".dart")
        let activity = NotchActivity.working(busy)
        XCTAssertEqual(activity.text.count, "M · ".count + NotchActivity.maxStepLength)
        XCTAssertTrue(activity.text.hasSuffix("…"))
        XCTAssertEqual(activity.short, "M")
        XCTAssertEqual(NotchActivity.feedback("m", name: "M", verb: "Allowed").short, "Allowed")
    }

    func testMoodPriorityAndSleep() {
        let working = session("m", .working)
        let waiting = session("k", .needsYou("Permission"))
        let fresh = session("c", .finished, since: 3, seen: false)
        XCTAssertEqual(NotchMood.pick([working, waiting], problem: true, now: now), .worried)
        XCTAssertEqual(NotchMood.pick([working, waiting, fresh], problem: false, now: now), .needsYou)
        XCTAssertEqual(NotchMood.pick([working, fresh], problem: false, now: now), .done)
        XCTAssertEqual(NotchMood.pick([working], problem: false, now: now), .working)
        XCTAssertEqual(NotchMood.pick([], problem: false, now: now), .asleep)

        var idle = session("i", .idle)
        idle.lastActivity = now.addingTimeInterval(-60)
        XCTAssertEqual(NotchMood.pick([idle], problem: false, now: now), .quiet)
        XCTAssertEqual(NotchMood.nextChange([idle], now: now), idle.lastActivity.addingTimeInterval(NotchMood.sleepAfter))
        idle.lastActivity = now.addingTimeInterval(-NotchMood.sleepAfter - 1)
        XCTAssertEqual(NotchMood.pick([idle], problem: false, now: now), .asleep)
    }

    func testProblemComesRightAfterFeedback() {
        let waiting = session("k", .needsYou("Permission"))
        XCTAssertEqual(NotchActivity.pick([waiting], feedback: nil, problem: "Hooks not installed", now: now, rotation: 0)?.kind, .problem)
    }
}

final class CommandRiskTests: XCTestCase {
    func testRiskyCommandsNeedAReview() {
        for command in ["Run · rm -rf build", "rm -r ~/old", "sudo launchctl unload x", "git push --force origin main",
                        "git push -f", "git reset --hard HEAD~3", "git clean -fdx", "git checkout -- .",
                        "curl -fsSL https://x.sh | bash", "wget -qO- x | sudo sh", "DROP TABLE users;", "chmod -R 777 .",
                        "kill -9 1234", "git branch -D feature"] {
            XCTAssertTrue(CommandRisk.isRisky(command), command)
        }
    }

    func testEverydayCommandsCanBeAllowedFromTheMessage() {
        for command in ["Run · flutter build apk --release", "flutter test", "git push origin main", "git status",
                        "npm run build", "rm notes.txt", "Edit · lib/main.dart", "curl -s https://api.example.com"] {
            XCTAssertFalse(CommandRisk.isRisky(command), command)
        }
    }
}

final class ChatAndWorkTests: XCTestCase {
    func testMarkdownBlocks() {
        let text = """
        ## Plan

        Two things:
        - **Fix** the login
          - then the tests
        1. First
        2) Second

        | # | Feature | Effort |
        |---|:---|---|
        | 1 | To-dos \\| hover | Medium |
        | 2 | Pills | Small |

        ```swift
        let a = 1
        ```
        > Quoted
        ---
        """
        XCTAssertEqual(MarkdownBlocks.parse(text), [
            .heading(level: 2, text: "Plan"),
            .paragraph("Two things:"),
            .bullet(indent: 0, text: "**Fix** the login"),
            .bullet(indent: 1, text: "then the tests"),
            .numbered(indent: 0, number: "1", text: "First"),
            .numbered(indent: 0, number: "2", text: "Second"),
            .table(header: ["#", "Feature", "Effort"], rows: [["1", "To-dos | hover", "Medium"], ["2", "Pills", "Small"]]),
            .code(language: "swift", text: "let a = 1"),
            .quote("Quoted"),
            .rule,
        ])
    }

    private func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testClaudeTaskListFromTaskTools() {
        var state = TranscriptState()
        func assistant(_ blocks: [[String: Any]]) -> Data {
            line(["type": "assistant", "timestamp": "2026-10-01T08:00:00.000Z", "message": ["id": UUID().uuidString, "content": blocks]])
        }
        func result(_ id: String, _ text: String) -> Data {
            line(["type": "user", "timestamp": "2026-10-01T08:00:01.000Z",
                  "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": text]]]])
        }
        state.consume(line: assistant([["type": "tool_use", "id": "t1", "name": "TaskCreate", "input": ["subject": "Scaffold"]]]))
        state.consume(line: result("t1", "Task #1 created successfully: Scaffold"))
        state.consume(line: assistant([["type": "tool_use", "id": "t2", "name": "TaskCreate", "input": ["subject": "Notch UI"]]]))
        state.consume(line: result("t2", "Task #2 created successfully: Notch UI"))
        state.consume(line: assistant([["type": "tool_use", "id": "t3", "name": "TaskCreate", "input": ["subject": "Tests"]]]))
        state.consume(line: result("t3", "Task #3 created successfully: Tests"))
        state.consume(line: assistant([["type": "tool_use", "id": "u1", "name": "TaskUpdate", "input": ["taskId": "1", "status": "completed"]]]))
        state.consume(line: assistant([["type": "tool_use", "id": "u2", "name": "TaskUpdate", "input": ["taskId": "2", "status": "in_progress"]]]))
        XCTAssertEqual(state.tasks.map(\.text), ["Scaffold", "Notch UI", "Tests"])
        let glance = state.tasks.glance
        XCTAssertEqual(glance.done?.text, "Scaffold")
        XCTAssertEqual(glance.current?.text, "Notch UI")
        XCTAssertEqual(glance.next?.text, "Tests")
        XCTAssertEqual(state.tasks.doneCount, 1)
    }

    func testClaudesQuestionsAndAnswersAreInTheChat() {
        var state = TranscriptState()
        func assistant(_ blocks: [[String: Any]]) -> Data {
            line(["type": "assistant", "timestamp": "2026-10-01T08:00:00.000Z", "message": ["id": UUID().uuidString, "content": blocks]])
        }
        let questions: [[String: Any]] = [[
            "question": "How should the repo go public?", "header": "Public repo", "multiSelect": false,
            "options": [["label": "Fresh public repo (Recommended)", "description": "One clean commit."],
                        ["label": "Make this repo public", "description": "Keeps the history."]],
        ]]
        state.consume(line: line(["type": "user", "timestamp": "2026-10-01T07:59:00.000Z", "message": ["content": "Release it"]]))
        state.consume(line: assistant([["type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": ["questions": questions]]]))
        guard case .message(let asked)? = state.chat.last else { return XCTFail("the question isn't in the chat") }
        XCTAssertEqual(asked.questions.first?.header, "Public repo")
        XCTAssertTrue(asked.answers.isEmpty)
        XCTAssertNil(asked.answerNote)
        XCTAssertEqual(state.timeline.last?.text, "Ask · Public repo")

        // Answered: Claude Code's structured result
        state.consume(line: line(["type": "user", "timestamp": "2026-10-01T08:00:30.000Z",
                                  "toolUseResult": ["answers": ["How should the repo go public?": "Fresh public repo (Recommended)"]],
                                  "message": ["content": [["type": "tool_result", "tool_use_id": "q1",
                                                           "content": "Your questions have been answered: …"]]]]))
        guard case .message(let answered)? = state.chat.last else { return XCTFail() }
        XCTAssertEqual(answered.answers["How should the repo go public?"], "Fresh public repo (Recommended)")
        XCTAssertTrue(answered.text.contains("Fresh public repo (Recommended) ✓"))
        let item = ChatSnapshot(sessionId: "s", chat: state.chat).items.last
        XCTAssertEqual(item?.role, .claude)
        XCTAssertEqual(item?.questions?.count, 1)
        XCTAssertEqual(item?.answers?["How should the repo go public?"], "Fresh public repo (Recommended)")

        // From the result text alone, and a skipped one
        state.consume(line: assistant([["type": "tool_use", "id": "q2", "name": "AskUserQuestion", "input": ["questions": questions]]]))
        state.consume(line: line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "q2",
            "content": "Your questions have been answered: \"How should the repo go public?\"=\"Make this repo public\". You can now continue."]]]]))
        guard case .message(let fromText)? = state.chat.last else { return XCTFail() }
        XCTAssertEqual(fromText.answers["How should the repo go public?"], "Make this repo public")
        state.consume(line: assistant([["type": "tool_use", "id": "q3", "name": "AskUserQuestion", "input": ["questions": questions]]]))
        state.consume(line: line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "q3", "is_error": true,
            "content": "The user doesn't want to proceed with this tool use. To tell you how to proceed, the user said:\nUse the old repo\n"]]]]))
        guard case .message(let skipped)? = state.chat.last else { return XCTFail() }
        XCTAssertEqual(skipped.answerNote, "Use the old repo")
    }

    func testClearerStepNames() {
        XCTAssertEqual(Session.stepLabel(tool: "SendMessage", input: ["to": "moussa-e1"]), "Message · moussa-e1")
        XCTAssertEqual(Session.stepLabel(tool: "AskUserQuestion", input: [:]), "Ask")
        XCTAssertEqual(Session.stepLabel(tool: "ToolSearch", input: ["query": "select:Read"]), "Load tools")
    }

    func testSubagentStepAndFinish() {
        var agent = SubagentState()
        agent.consume(line: line(["type": "assistant", "timestamp": "2026-10-01T08:00:00.000Z",
                                  "message": ["content": [["type": "tool_use", "name": "Grep", "input": ["pattern": "auth"]]],
                                              "stop_reason": "tool_use"]]))
        XCTAssertFalse(agent.finished)
        XCTAssertNotNil(agent.lastStep)
        agent.consume(line: line(["type": "assistant", "message": ["content": [["type": "text", "text": "Found it."]],
                                                                   "stop_reason": "end_turn"]]))
        XCTAssertTrue(agent.finished)
    }

    func testStopFailureIsAnErrorUntilNewWork() {
        let now = Date()
        var session = Session(id: "s", cwd: "/p/app", host: .ghostty, now: now)
        session.apply(HookEvent(name: "StopFailure", sessionId: "s", cwd: "/p/app", host: .ghostty, error: "Overloaded"), now: now)
        XCTAssertTrue(session.failed)
        XCTAssertEqual(session.errorText, "Overloaded")
        XCTAssertEqual(NotchMood.pick([session], problem: false, now: now), .worried)
        XCTAssertEqual(NotchActivity.pick([session], feedback: nil, now: now, rotation: 0)?.kind, .failed)
        session.apply(HookEvent(name: "UserPromptSubmit", sessionId: "s", cwd: "/p/app", host: .ghostty), now: now)
        XCTAssertFalse(session.failed)
    }
}


final class PermissionDataTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func request(_ payload: [String: Any]) -> PendingApproval? {
        var full: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/Users/me/lumen"]
        full.merge(payload) { $1 }
        guard let event = HookEvent.parse(full) else { return nil }
        var session = Session(id: "s", cwd: "/Users/me/lumen", host: .ghostty, now: t0)
        session.apply(event, now: t0)
        return session.pendingApproval
    }

    func testBashKeepsTheFullCommandBesideItsDescription() throws {
        let long = "flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols --target-platform android-arm64"
        let approval = try XCTUnwrap(request(["tool_name": "Bash",
                                              "tool_input": ["command": long, "description": "Build the release APK"]]))
        XCTAssertEqual(approval.command, long)
        XCTAssertEqual(approval.description, "Build the release APK")
        XCTAssertEqual(approval.title, "Build the release APK")
        XCTAssertEqual(approval.kind, .command)
        XCTAssertEqual(approval.cwd, "/Users/me/lumen")
    }

    func testRiskIsJudgedOnTheCommandNotTheDescription() throws {
        let approval = try XCTUnwrap(request(["tool_name": "Bash",
                                              "tool_input": ["command": "rm -rf build", "description": "Clean build output"]]))
        XCTAssertEqual(approval.detail, "Run · Clean build output")
        XCTAssertFalse(CommandRisk.isRisky(approval.detail))
        XCTAssertTrue(approval.isRisky)
    }

    func testEditKeepsOldAndNew() throws {
        let approval = try XCTUnwrap(request(["tool_name": "Edit",
                                              "tool_input": ["file_path": "/p/lib/main.dart", "old_string": "a\nb", "new_string": "a\nc"]]))
        XCTAssertEqual(approval.kind, .edit)
        XCTAssertEqual(approval.fileName, "main.dart")
        XCTAssertEqual(approval.edits, [TextEdit(oldString: "a\nb", newString: "a\nc")])
        XCTAssertEqual(approval.diff?.counts, "+1 −1")
    }

    func testMultiEditKeepsItsEdits() throws {
        let edits: [[String: Any]] = [["old_string": "x", "new_string": "y"], ["old_string": "one\ntwo", "new_string": "one"]]
        let approval = try XCTUnwrap(request(["tool_name": "MultiEdit", "tool_input": ["file_path": "/p/a.swift", "edits": edits]]))
        XCTAssertEqual(approval.edits.count, 2)
        let diff = try XCTUnwrap(approval.diff)
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 2)
        XCTAssertTrue(diff.lines.contains { $0.kind == .gap })
    }

    func testAlwaysNamesTheRuleItSaves() throws {
        let suggestions: [[String: Any]] = [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                             "rules": [["toolName": "Bash", "ruleContent": "flutter build:*"]]]]
        let approval = try XCTUnwrap(request(["tool_name": "Bash", "tool_input": ["command": "flutter build apk"],
                                              "permission_suggestions": suggestions]))
        XCTAssertEqual(approval.rules, ["Bash(flutter build:*)"])
    }

    func testLineDiff() {
        let diff = LineDiff.make(old: "1\n2\n3\n4\n5\n6\n7", new: "1\n2\nthree\n4\n5\n6\n7\n8")
        XCTAssertEqual(diff.counts, "+2 −1")
        XCTAssertEqual(diff.lines.map(\.kind), [.context, .removed, .added, .context, .gap, .context, .added])
        XCTAssertEqual(LineDiff.make(old: "", new: "a\nb").counts, "+2 −0")
        XCTAssertTrue(LineDiff.make(old: "same", new: "same").lines.isEmpty)
    }
}

final class RateLimitTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDetectsTheLimitAndWhenItResets() {
        let message = "Claude usage limit reached. Your limit will reset at 9pm (Asia/Kuwait)."
        XCTAssertTrue(RateLimit.isLimit(message))
        XCTAssertEqual(RateLimit.resetTime(message), "9pm (Asia/Kuwait)")
        XCTAssertEqual(RateLimit.resetTime("5-hour limit reached ∙ resets 10:30am"), "10:30am")
        XCTAssertTrue(RateLimit.isLimit("rate_limit_error"))
        XCTAssertFalse(RateLimit.isLimit("Claude needs your permission to use Bash"))
        XCTAssertNil(RateLimit.resetTime("resets 3 sessions"))
    }

    func testASessionAtTheLimitIsMarkedAndClearsOnTheNextPrompt() {
        var session = Session(id: "s", cwd: "/p", host: .ghostty, now: t0)
        session.apply(HookEvent(name: "StopFailure", sessionId: "s", message: "5-hour limit reached ∙ resets 9pm",
                                error: "rate_limit"), now: t0)
        XCTAssertTrue(session.rateLimited)
        XCTAssertEqual(session.limitReset, "9pm")
        XCTAssertEqual(NotchMood.pick([session], problem: false, now: t0), .needsYou)
        XCTAssertEqual(NotchActivity.pick([session], feedback: nil, now: t0, rotation: 0)?.kind, .limited)
        session.apply(HookEvent(name: "UserPromptSubmit", sessionId: "s"), now: t0 + 60)
        XCTAssertFalse(session.rateLimited)
    }
}

final class RemoteControlTests: XCTestCase {
    func testTheRegistryTellsWhenRemoteControlIsOn() throws {
        let on = #"{"pid": 27859, "sessionId": "ce53", "cwd": "/Users/me", "status": "idle", "bridgeSessionId": "session_018Rad"}"#
        let off = #"{"pid": 70832, "sessionId": "c5ba", "cwd": "/Users/me", "status": "busy"}"#
        let entry = try XCTUnwrap(RegistryEntry.parse(Data(on.utf8)))
        XCTAssertEqual(entry.bridgeSessionId, "session_018Rad")
        XCTAssertNil(try XCTUnwrap(RegistryEntry.parse(Data(off.utf8))).bridgeSessionId)
        var session = Session(id: "ce53", cwd: "/Users/me", host: .ghostty, now: Date())
        session.apply(entry, host: .ghostty, tty: nil, transcriptPath: nil, now: Date())
        XCTAssertEqual(session.remoteSessionId, "session_018Rad")
    }
}

final class ChoiceQuestionTests: XCTestCase {
    func testShortChoicesAfterAColonBecomeAnswers() throws {
        let found = try XCTUnwrap(ClosingQuestion.find(in: "Both work.\n\nWhich icon set should I use: Lucide or Heroicons?"))
        XCTAssertEqual(found.answers.map(\.text), ["Lucide", "Heroicons"])
        let three = try XCTUnwrap(ClosingQuestion.find(in: "Pick one: Riverpod, Bloc, or Provider?"))
        XCTAssertEqual(three.answers.map(\.label), ["Riverpod", "Bloc", "Provider"])
    }

    func testLongOptionsStayAQuestionWithoutAnswers() {
        let long = "Next step: should I rewrite the whole sync engine from scratch or keep patching the old one?"
        XCTAssertEqual(ClosingQuestion.find(in: long)?.answers, [])
    }
}

final class ActivityLogTests: XCTestCase {
    private func entry(_ kind: ActivityEntry.Kind, _ text: String, at: Date, session: String = "a") -> ActivityEntry {
        ActivityEntry(at: at, sessionId: session, name: "Trailmap", colorKey: "/x/trailmap", kind: kind, text: text)
    }

    func testKeepsTwoDaysNewestFirstAndDropsRepeats() {
        let now = Date()
        var log = ActivityLog()
        log.add(entry(.finished, "Old", at: now.addingTimeInterval(-50 * 3600)))
        log.add(entry(.started, "Fix the login", at: now.addingTimeInterval(-60)))
        log.add(entry(.started, "Fix the login", at: now.addingTimeInterval(-50)))
        log.add(entry(.asked, "Run a command", at: now))
        XCTAssertEqual(log.entries.map(\.text), ["Fix the login", "Run a command"])
        XCTAssertEqual(log.recent(within: 24 * 3600, now: now).map(\.kind), [.asked, .started])
    }

    func testCapsTheNumberOfEntries() {
        let now = Date()
        var log = ActivityLog()
        for index in 0..<(ActivityLog.cap + 20) {
            log.add(entry(.finished, "Turn \(index)", at: now.addingTimeInterval(Double(index)), session: "s\(index)"))
        }
        XCTAssertEqual(log.entries.count, ActivityLog.cap)
        XCTAssertEqual(log.entries.first?.text, "Turn 20")
    }

    func testRoundTripsThroughJSON() throws {
        var log = ActivityLog()
        log.add(entry(.limited, "Usage limit · resets 9pm", at: Date()))
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(ActivityLog.self, from: data), log)
    }
}

final class QuestionToolTests: XCTestCase {
    private let toolInput: [String: Any] = [
        "questions": [[
            "question": "Which icon set should I use?", "header": "Icons", "multiSelect": false,
            "options": [["label": "Lucide", "description": "Outline icons"], ["label": "Heroicons", "description": ""]],
        ]],
    ]

    func testAPermissionRequestForTheQuestionToolBecomesAQuestion() throws {
        let payload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/x",
                                      "tool_name": "AskUserQuestion", "tool_input": toolInput]
        let event = try XCTUnwrap(HookEvent.parse(payload))
        let approval = PendingApproval(event: event, at: Date())
        XCTAssertEqual(approval.kind, .question)
        XCTAssertEqual(approval.title, "Which icon set should I use?")
        XCTAssertEqual(approval.questions.first?.options.map(\.label), ["Lucide", "Heroicons"])
        XCTAssertNil(approval.questions.first?.options.last?.description, "an empty description is no description")
        var session = Session(id: "s1", cwd: "/x", host: .ghostty, now: Date())
        session.apply(event, now: Date())
        XCTAssertEqual(session.status, .needsYou("Which icon set should I use?"))
        XCTAssertNil(event.agentId, "the main session's own question")

        // Claude Code's reminder a few seconds later keeps the question as the reason
        session.apply(HookEvent(name: "Notification", sessionId: "s1",
                                message: "Claude needs your permission to use AskUserQuestion"), now: Date())
        XCTAssertEqual(session.status, .needsYou("Which icon set should I use?"))
        XCTAssertNotNil(session.pendingApproval)
    }

    func testAQuestionFromASubagentSaysSo() throws {
        let payload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s1", "agent_id": "a7",
                                      "tool_name": "AskUserQuestion", "tool_input": toolInput]
        XCTAssertEqual(HookEvent.parse(payload)?.agentId, "a7")
    }

    func testAnswersTravelOverTheSocketAndIntoUpdatedInput() throws {
        let answers = QuestionAnswers(answers: ["Which icon set should I use?": "Lucide"])
        let line = PermissionDecision.socketLine(.allow, extras: ReplyExtras(answers: answers))
        let parsed = PermissionDecision.parseReply(socketLine: Data(line.utf8.dropLast()))
        XCTAssertEqual(parsed.decision, .allow)
        XCTAssertEqual(parsed.extras?.answers, answers)

        let output = try XCTUnwrap(parsed.decision.hookOutput(permissionSuggestions: nil, extras: parsed.extras, toolInput: toolInput))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let decision = try XCTUnwrap((object["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which icon set should I use?": "Lucide"])
        XCTAssertNotNil(updated["questions"], "the questions go back with the answers")
    }

    func testOwnWordsGoInTheResponseAndAPlainAllowStaysPlain() throws {
        let own = QuestionAnswers(response: "Use SF Symbols instead")
        let updated = own.updatedInput(from: toolInput)
        XCTAssertEqual(updated["response"] as? String, "Use SF Symbols instead")
        XCTAssertNil(PermissionDecision.parseReply(socketLine: Data(PermissionDecision.allow.socketLine.utf8)).extras)
        let plain = try XCTUnwrap(PermissionDecision.allow.hookOutput(permissionSuggestions: nil))
        XCTAssertFalse(plain.contains("updatedInput"))
    }
}

final class PlanUsageTests: XCTestCase {
    func testReadsThePlanAndTheContextFromTheStatusLine() throws {
        let json = #"{"session_id":"s1","context_window":{"used_percentage":63.4},"rate_limits":{"five_hour":{"used_percentage":23,"resets_at":1790944800},"seven_day":{"used_percentage":41,"resets_at":"2026-10-05T07:00:00Z"}}}"#
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let info = StatusLineInfo.parse(payload)
        XCTAssertEqual(info.sessionId, "s1")
        XCTAssertEqual(info.contextPercent, 63.4)
        XCTAssertEqual(info.usage?.session?.percent, 23)
        XCTAssertEqual(info.usage?.session?.resetsAt, Date(timeIntervalSince1970: 1790944800))
        XCTAssertEqual(info.usage?.week?.percent, 41)
        XCTAssertNotNil(info.usage?.week?.resetsAt, "an ISO date works too")
        XCTAssertEqual(info.usage?.peak, 41)
    }

    func testNoLimitsMeansNoUsage() {
        XCTAssertNil(StatusLineInfo.parse(["session_id": "s1", "context_window": ["used_percentage": 10]]).usage)
    }
}

final class PlanApprovalTests: XCTestCase {
    func testExitPlanModeBecomesAPlanAndItsApprovalKeepsTheInput() throws {
        let plan = "# Plan: Add the login screen\n\n1. Build the form\n2. Wire Firebase"
        let payload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "s1", "cwd": "/x",
                                      "tool_name": "ExitPlanMode", "tool_input": ["plan": plan]]
        let event = try XCTUnwrap(HookEvent.parse(payload))
        let approval = PendingApproval(event: event, at: Date())
        XCTAssertEqual(approval.kind, .plan)
        XCTAssertEqual(approval.title, "Add the login screen")

        let line = PermissionDecision.socketLine(.allow, extras: ReplyExtras(keepInput: true, mode: "acceptEdits"))
        let parsed = PermissionDecision.parseReply(socketLine: Data(line.utf8))
        let output = try XCTUnwrap(parsed.decision.hookOutput(permissionSuggestions: nil, extras: parsed.extras, toolInput: ["plan": plan]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let decision = try XCTUnwrap((object["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual((decision["updatedInput"] as? [String: Any])?["plan"] as? String, plan)
        let mode = try XCTUnwrap((decision["updatedPermissions"] as? [[String: Any]])?.first)
        XCTAssertEqual(mode["type"] as? String, "setMode")
        XCTAssertEqual(mode["mode"] as? String, "acceptEdits")
    }

    func testKeepPlanningSendsYourWords() throws {
        let line = PermissionDecision.socketLine(.deny, extras: ReplyExtras(message: "Use Riverpod, not Bloc"))
        let parsed = PermissionDecision.parseReply(socketLine: Data(line.utf8))
        let output = try XCTUnwrap(parsed.decision.hookOutput(permissionSuggestions: nil, extras: parsed.extras))
        XCTAssertTrue(output.contains("Use Riverpod, not Bloc"))
    }
}

final class ResetAndForecastTests: XCTestCase {
    func testResetTimesBecomeTheNextMatchingMoment() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let morning = try XCTUnwrap(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date()))
        let nine = try XCTUnwrap(RateLimit.resetDate("9pm", now: morning))
        XCTAssertEqual(calendar.component(.hour, from: nine), 21)
        XCTAssertTrue(calendar.isDate(nine, inSameDayAs: morning))
        let early = try XCTUnwrap(RateLimit.resetDate("3:45am", now: morning))
        XCTAssertGreaterThan(early, morning, "a time already past today means tomorrow")
        XCTAssertNil(RateLimit.resetDate("soon", now: morning))
    }

    func testForecastsFromThePaceSoFar() {
        let now = Date()
        // Half the week gone, 70% used: runs out before it resets
        let fast = UsageWindow(percent: 70, resetsAt: now.addingTimeInterval(UsageForecast.weekLength / 2))
        XCTAssertNotNil(UsageForecast.runsOut(fast, length: UsageForecast.weekLength, now: now))
        // Half gone, 30% used: lands near 60%
        let slow = UsageWindow(percent: 30, resetsAt: now.addingTimeInterval(UsageForecast.weekLength / 2))
        XCTAssertNil(UsageForecast.runsOut(slow, length: UsageForecast.weekLength, now: now))
        XCTAssertEqual(UsageForecast.percentAtReset(slow, length: UsageForecast.weekLength, now: now) ?? 0, 60, accuracy: 0.5)
        // Too early in the window to say
        let early = UsageWindow(percent: 5, resetsAt: now.addingTimeInterval(UsageForecast.weekLength * 0.95))
        XCTAssertNil(UsageForecast.percentAtReset(early, length: UsageForecast.weekLength, now: now))
    }
}

final class GitStateTests: XCTestCase {
    func testReadsChangesAndUnpushedCommits() {
        let state = GitState.parse("## main...origin/main [ahead 2]\n M Sources/App/main.swift\n?? new.swift\n")
        XCTAssertEqual(state, GitState(branch: "main", ahead: 2, changed: 2, hasUpstream: true))
        XCTAssertTrue(state.unsaved)
        XCTAssertFalse(GitState.parse("## main...origin/main\n").unsaved)
        XCTAssertEqual(GitState.parse("## feature\n M a\n"), GitState(branch: "feature", ahead: 0, changed: 1, hasUpstream: false))
        XCTAssertEqual(GitState.parse("## No commits yet on main\n?? a\n").branch, "main")
    }
}

final class AppVersionTests: XCTestCase {
    func testComparesReleaseTagsWithTheAppVersion() {
        XCTAssertTrue(AppVersion.isNewer("v0.2.0", than: "0.1.0"))
        XCTAssertTrue(AppVersion.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertFalse(AppVersion.isNewer("v0.1.0", than: "0.1.0"))
        XCTAssertFalse(AppVersion.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(AppVersion.isNewer("v1.0.0-beta", than: "1.0.0"))
    }
}

final class PhoneSyncTests: XCTestCase {
    func testASessionWaitingOnAQuestionTravelsWithItsChoices() throws {
        var session = Session(id: "s1", cwd: "/x/app", host: .ghostty, now: Date())
        let question = AskedQuestion(question: "Which icon set?", options: [.init(label: "Lucide"), .init(label: "Heroicons")])
        session.pendingApproval = PendingApproval(tool: "AskUserQuestion", detail: "AskUserQuestion", requestedAt: Date(), questions: [question])
        session.status = .needsYou("Which icon set?")
        let snapshot = SessionSnapshot(session: session, name: "App", colorKey: "/x/app", task: nil, held: true, limitReset: nil)
        XCTAssertEqual(snapshot.state, .needsYou)
        XCTAssertEqual(snapshot.prompt?.kind, .question)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(SessionSnapshot(session: session, name: "App", colorKey: "", task: nil, held: false, limitReset: nil).prompt,
                     "a prompt WatchMan doesn't hold can't be answered from the phone")
    }

    func testCommandsRoundTripAndGoStale() throws {
        let command = PhoneCommand(sessionId: "s1", kind: .answer(QuestionAnswers(answers: ["Which icon set?": "Lucide"])))
        XCTAssertEqual(try JSONDecoder().decode(PhoneCommand.self, from: JSONEncoder().encode(command)), command)
        let old = PhoneCommand(sessionId: "s1", kind: .allow, created: Date().addingTimeInterval(-PhoneCommand.maxAge - 1))
        XCTAssertTrue(old.isStale())
        XCTAssertFalse(command.isStale())
    }
}

final class PhoneRemoteTests: XCTestCase {
    private let settings = MacSettings(approvalsEnabled: true, handBackSeconds: 90, awayHoldMinutes: 9, awayAfterMinutes: 5,
                                       iphoneAlerts: true, iphoneAlertsWhenAway: true, autoContinue: false, notchMessages: true,
                                       sounds: true, volume: 0.6, quietUntil: nil, quietWhilePresenting: true, stuckAlerts: true,
                                       stuckIdleMinutes: 10, stuckRepeatCount: 3, stuckLongRunMinutes: 45, devLog: true,
                                       devLogMinutes: 23 * 60, devLogHaiku: true, quickReplies: ["continue"])

    func testChangesFromThePhoneStayInTheMacsRanges() {
        XCTAssertEqual(settings.applying(.handBackSeconds(500)).handBackSeconds, 110)
        XCTAssertEqual(settings.applying(.awayHoldMinutes(1)).awayHoldMinutes, 2)
        XCTAssertEqual(settings.applying(.stuckRepeatCount(50)).stuckRepeatCount, 10)
        XCTAssertEqual(settings.applying(.volume(3)).volume, 1)
        XCTAssertEqual(settings.applying(.devLogMinutes(5000)).devLogMinutes, 24 * 60 - 1)
        XCTAssertEqual(settings.applying(.quickReplies([" run the tests ", "", "  "])).quickReplies, ["run the tests"])
        XCTAssertEqual(settings.applying(.approvals(false)).approvalsEnabled, false)
        XCTAssertEqual(settings.applying(.muted(project: "/x", true)), settings, "muting is a project's, not a setting")
    }

    func testOnlyRealChatIdsGoOnTheResumeCommandLine() {
        XCTAssertTrue(MacCommand.isChatId("878c8dde-97dc-492f-beb2-bc0696618ebe"))
        XCTAssertFalse(MacCommand.isChatId("878c8dde-97dc-492f-beb2-bc0696618ebe; rm -rf ~"))
        XCTAssertFalse(MacCommand.isChatId("$(say hi)"))
        XCTAssertFalse(MacCommand.isChatId(""))
    }

    func testMacCommandsTravelInsidePhoneCommands() throws {
        let commands: [MacCommand] = [.stop, .setting(.quietUntil(Date(timeIntervalSince1970: 1_800_000_000))),
                                      .setting(.muted(project: "/Users/me/App", true)), .start(folder: "/Users/me/App", prompt: "/app-audit"),
                                      .resume(chatId: "878c8dde-97dc-492f-beb2-bc0696618ebe", folder: "/Users/me/App"),
                                      .refresh(.system), .search("icon set"), .askProject(root: "/Users/me/App", .push),
                                      .quitLeftover(pid: 4242), .removeFollowUp(1)]
        for command in commands {
            let phone = PhoneCommand(sessionId: "s1", kind: .mac(command))
            let decoded = try JSONDecoder().decode(PhoneCommand.self, from: JSONEncoder().encode(phone))
            XCTAssertEqual(decoded.kind, .mac(command))
        }
    }

    func testAStatusWrittenBeforeExtrasStillReads() throws {
        let old = #"{"macName":"MacBook Pro","updated":0}"#
        let status = try JSONDecoder().decode(MacStatus.self, from: Data(old.utf8))
        XCTAssertNil(status.extras)
        var extras = MacExtras(settings: settings)
        extras.unsaved = [UnsavedSnapshot(root: "/x", name: "x", colorKey: "x", branch: "main", changed: 3, ahead: 1,
                                          hasUpstream: true, canAsk: true)]
        let new = MacStatus(macName: "Mac", usage: nil, updated: Date(), extras: extras)
        XCTAssertEqual(try JSONDecoder().decode(MacStatus.self, from: JSONEncoder().encode(new)).extras, extras)
        XCTAssertEqual(extras.unsaved?.first?.summary, "3 files changed · 1 commit not pushed")
    }
}

final class PhoneChatAndChangesTests: XCTestCase {
    private func message(_ i: Int, _ text: String) -> TranscriptState.ChatItem {
        .message(.init(id: i, at: Date(timeIntervalSince1970: Double(i)), fromYou: i % 2 == 0, text: text))
    }

    func testAChatCarriesTheNewestItemsAndSaysHowManyThereAre() {
        let chat = (0..<120).map { message($0, "message \($0)") }
        let snapshot = ChatSnapshot(sessionId: "s1", chat: chat)
        XCTAssertEqual(snapshot.items.count, ChatSnapshot.maxItems)
        XCTAssertEqual(snapshot.items.last?.text, "message 119")
        XCTAssertEqual(snapshot.total, 120)
        XCTAssertEqual(ChatSnapshot(sessionId: "s1", chat: chat, limit: 100).items.count, 100)
        XCTAssertEqual(ChatSnapshot(sessionId: "s1", chat: chat, limit: 10_000).items.count, 120)
    }

    func testALongChatStaysInsideTheRecordBudget() {
        let long = String(repeating: "x", count: ChatSnapshot.maxCharacters)
        let chat = (0..<ChatSnapshot.largestLimit).map { message($0, long) }
        let snapshot = ChatSnapshot(sessionId: "s1", chat: chat, limit: ChatSnapshot.largestLimit)
        XCTAssertEqual(snapshot.items.count, ChatSnapshot.maxTotalCharacters / ChatSnapshot.maxCharacters)
        XCTAssertEqual(snapshot.items.last?.at, Date(timeIntervalSince1970: Double(ChatSnapshot.largestLimit - 1)), "the newest stay")
    }

    func testDiffsLoseGitsHeadersAndStopAtTheBudget() {
        let diff = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-old\n+new\n same"
        let hunks = ProjectChanges.hunks(diff, budget: 100)
        XCTAssertEqual(hunks.lines, ["@@ -1,2 +1,2 @@", "-old", "+new", " same"])
        XCTAssertFalse(hunks.cut)
        let short = ProjectChanges.hunks(diff, budget: 2)
        XCTAssertEqual(short.lines.count, 2)
        XCTAssertTrue(short.cut)
    }
}

final class GlanceTests: XCTestCase {
    private let now = Date()

    private func session(_ id: String, _ state: SessionSnapshot.State, ago: TimeInterval, updatedAgo: TimeInterval = 0,
                         prompt: PromptSnapshot? = nil, unseen: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: id, name: id.uppercased(), task: nil, colorKey: id, host: "Ghostty", canReply: true, state: state,
                        detail: "Run · make", since: now.addingTimeInterval(-ago), unseen: unseen, prompt: prompt,
                        contextPercent: nil, limitReset: nil, updated: now.addingTimeInterval(-updatedAgo))
    }

    private func question(_ options: [String], multiSelect: Bool = false, count: Int = 1) -> PromptSnapshot {
        let asked = (0..<count).map { index in
            AskedQuestion(question: "Which one \(index)?", header: nil, options: options.map { .init(label: $0) },
                          multiSelect: multiSelect)
        }
        return PromptSnapshot(approval: PendingApproval(tool: "AskUserQuestion", detail: "AskUserQuestion", requestedAt: now,
                                                        questions: asked))
    }

    func testWaitingComesFirstLongestWaitingFirstThenTheLatestWork() {
        let glance = Glance(sessions: [
            session("done", .done, ago: 10, unseen: true),
            session("old-work", .working, ago: 600, updatedAgo: 300),
            session("new-wait", .needsYou, ago: 60),
            session("new-work", .working, ago: 900, updatedAgo: 5),
            session("old-wait", .limited, ago: 900),
        ], usage: nil, macName: "Mac", updated: now)
        XCTAssertEqual(glance.sessions.map(\.id), ["new-wait", "old-wait", "new-work", "old-work", "done"])
        XCTAssertEqual(glance.waiting.count, 2)
        XCTAssertEqual(glance.working.count, 2)
        XCTAssertEqual(glance.newResults.map(\.id), ["done"])
        XCTAssertTrue(glance.busy)
    }

    func testTheFocusIsAPromptToAnswerBeforeAnythingElse() {
        let glance = Glance(sessions: [
            session("limit", .limited, ago: 900),
            session("asks", .needsYou, ago: 30, prompt: question(["A", "B"])),
            session("works", .working, ago: 10),
        ], usage: nil, macName: "Mac", updated: now)
        XCTAssertEqual(glance.focus?.id, "asks")
        XCTAssertEqual(glance.focus?.prompt?.heading, "ASKS asks")
        XCTAssertEqual(glance.focus?.prompt?.text, "Which one 0?")

        let quiet = Glance(sessions: [session("idle", .idle, ago: 10), session("done", .done, ago: 5)],
                           usage: nil, macName: "Mac", updated: now)
        XCTAssertNil(quiet.focus)
        XCTAssertFalse(quiet.busy)
    }

    func testOnlyOneQuestionWithAFewChoicesGetsButtons() {
        XCTAssertEqual(Glance.Prompt(question(["A", "B", "C"]), session: "S").choices, ["A", "B", "C"])
        XCTAssertEqual(Glance.Prompt(question(["A", "B", "C", "D", "E"]), session: "S").choices, [])
        XCTAssertEqual(Glance.Prompt(question(["A", "B"], multiSelect: true), session: "S").choices, [])
        XCTAssertEqual(Glance.Prompt(question(["A", "B"], count: 2), session: "S").choices, [])
    }

    func testAGlanceRoundTrips() throws {
        let glance = Glance(sessions: [session("a", .needsYou, ago: 30, prompt: question(["A", "B"]))],
                            usage: PlanUsage(session: UsageWindow(percent: 23, resetsAt: nil), week: nil),
                            macName: "Mac", updated: now)
        let decoded = try JSONDecoder().decode(Glance.self, from: JSONEncoder().encode(glance))
        XCTAssertEqual(decoded, glance)
        XCTAssertEqual(decoded.sessionPercent, 23)
        XCTAssertNil(decoded.weekPercent)
    }

    func testTheFinishedTurnsSwitchTravelsAndOlderSettingsStillRead() throws {
        let settings = MacSettings(approvalsEnabled: true, handBackSeconds: 90, awayHoldMinutes: 9, awayAfterMinutes: 5,
                                   iphoneAlerts: true, iphoneAlertsWhenAway: true, autoContinue: false, notchMessages: true,
                                   sounds: true, volume: 0.6, quietUntil: nil, quietWhilePresenting: true, stuckAlerts: true,
                                   stuckIdleMinutes: 10, stuckRepeatCount: 3, stuckLongRunMinutes: 45, devLog: true,
                                   devLogMinutes: 23 * 60, devLogHaiku: true, quickReplies: [])
        XCTAssertNil(settings.iphoneFinishedAlerts)
        XCTAssertEqual(settings.applying(.iphoneFinishedAlerts(true)).iphoneFinishedAlerts, true)
        // Settings from a Mac before the switch existed still read
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json["iphoneFinishedAlerts"] = nil
        let old = try JSONDecoder().decode(MacSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.iphoneFinishedAlerts)
    }
}

final class PromptIdentityTests: XCTestCase {
    func testAnAnswerNeverReachesTheNextPrompt() {
        let asked = Date(timeIntervalSince1970: 1_800_000_000.123)
        let allow = PhoneCommand(sessionId: "s", kind: .allow, prompt: asked)
        XCTAssertFalse(allow.answersAnotherPrompt(than: asked))
        XCTAssertFalse(allow.answersAnotherPrompt(than: asked.addingTimeInterval(0.0004)), "rounding through JSON")
        XCTAssertTrue(allow.answersAnotherPrompt(than: asked.addingTimeInterval(30)), "a newer prompt")
        XCTAssertTrue(allow.answersAnotherPrompt(than: nil), "nothing waits any more")
        XCTAssertFalse(PhoneCommand(sessionId: "s", kind: .allow).answersAnotherPrompt(than: asked),
                       "without a prompt time: whichever waits, as before")
        XCTAssertFalse(PhoneCommand(sessionId: "s", kind: .reply("hi"), prompt: asked).answersAnotherPrompt(than: nil),
                       "a reply isn't an answer to a prompt")
    }

    func testAPromptsKeyTellsTwoAlikePromptsApart() {
        let first = Glance.Prompt(kind: .permission, heading: "A wants to run", text: "npm test", choices: [],
                                  asked: Date(timeIntervalSince1970: 100))
        var second = first
        second.asked = Date(timeIntervalSince1970: 160)
        XCTAssertNotEqual(first.key, second.key)
        var roundTripped = first
        roundTripped.asked = Date(timeIntervalSince1970: 100.0000001)
        XCTAssertEqual(first.key, roundTripped.key)
    }

    func testAVeryLongCommandIsCutForTheLiveActivity() {
        var approval = PendingApproval(tool: "Bash", detail: "Run", requestedAt: Date(), command: String(repeating: "x", count: 5000))
        approval.handBackAt = nil
        let prompt = Glance.Prompt(PromptSnapshot(approval: approval), session: "S")
        XCTAssertLessThanOrEqual(prompt.text.count, 201)
        XCTAssertEqual(prompt.heading, "S wants to run")
    }
}
