import Foundation

/// Runs command-line tools off the main thread.
enum Script {
    struct Result: Sendable {
        var status: Int32
        var output: String
        /// Output exactly as printed (leading spaces matter, e.g. for git status).
        var raw: String = ""
        /// What it printed on stderr, when asked for (AppleScript's error message).
        var error: String = ""
        var ok: Bool { status == 0 }
    }

    static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                    environment: [String: String]? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, input: input, environment: environment))
            }
        }
    }

    static func runBlocking(_ executable: String, _ arguments: [String], input: String? = nil,
                            environment: [String: String]? = nil, capturesErrors: Bool = false) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        process.standardOutput = out
        let errors = capturesErrors ? Pipe() : nil
        process.standardError = errors ?? FileHandle.nullDevice
        let inPipe = input.map { _ in Pipe() }
        if let inPipe { process.standardInput = inPipe }
        do { try process.run() } catch { return Result(status: -1, output: "") }
        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return Result(status: process.terminationStatus, output: text.trimmingCharacters(in: .whitespacesAndNewlines),
                      raw: text, error: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs AppleScript with its arguments passed as `argv` (never pasted into the source).
    static func appleScript(_ source: String, _ arguments: [String] = []) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking("/usr/bin/osascript", ["-e", source] + arguments, capturesErrors: true))
            }
        }
    }

    static func appleScriptBlocking(_ source: String, _ arguments: [String] = []) -> Result {
        runBlocking("/usr/bin/osascript", ["-e", source] + arguments)
    }

    /// Single-quotes a string for a shell command line.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
