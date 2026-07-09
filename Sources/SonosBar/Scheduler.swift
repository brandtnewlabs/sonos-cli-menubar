import Foundation

/// Owns the launchd job that runs the auto-group action even when the app is
/// closed.
///
/// The job runs **SonosBar's own binary** (`SonosBar --run-autogroup`), not a
/// shell script. This is deliberate: on modern macOS the responsible process
/// needs Local Network permission to reach speakers, and only a stable signed
/// app identity can hold that grant — a `/bin/zsh → sonos` agent is silently
/// denied and finds no speakers. Running the app binary means the scheduled run
/// shares the exact grant the GUI already has.
struct Scheduler {
    static let label = "sh.sonoscli.sonosbar.autogroup"

    /// Absolute path to SonosBar's own executable, baked into the plist.
    var appExecutablePath: String

    init(appExecutablePath: String = Scheduler.defaultAppExecutablePath) {
        self.appExecutablePath = appExecutablePath
    }

    static var defaultAppExecutablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    // MARK: File locations

    static var supportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SonosBar", isDirectory: true)
    }
    static var logURL: URL { supportDirectory.appendingPathComponent("autogroup.log") }
    static var plistURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Scheduler.plistURL.path)
    }

    // MARK: Public actions

    /// Writes the plist for `config` and (re)loads the launchd job.
    func install(_ config: AutoGroupConfig) async throws {
        let execPath = appExecutablePath
        try await onBackground {
            try Scheduler.ensureSupportDirectory()
            try Scheduler.writePlist(config: config, appExecutablePath: execPath)
            try Scheduler.reloadJob()
        }
    }

    /// Unloads the job and removes the plist.
    func uninstall() async throws {
        try await onBackground {
            Scheduler.bootout()  // best-effort; harmless if not loaded
            try? FileManager.default.removeItem(at: Scheduler.plistURL)
        }
    }

    // MARK: Plist generation

    static func plistContents(config: AutoGroupConfig, appExecutablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscape(appExecutablePath))</string>
                <string>--run-autogroup</string>
            </array>
            <key>StartCalendarInterval</key>
            <dict>
                <key>Hour</key>
                <integer>\(config.hour)</integer>
                <key>Minute</key>
                <integer>\(config.minute)</integer>
            </dict>
            <key>RunAtLoad</key>
            <false/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(logURL.path))</string>
        </dict>
        </plist>
        """
    }

    // MARK: Implementation

    private static func ensureSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true)
    }

    private static func writePlist(config: AutoGroupConfig, appExecutablePath: String) throws {
        let agentsDir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: agentsDir, withIntermediateDirectories: true)
        try plistContents(config: config, appExecutablePath: appExecutablePath)
            .write(to: plistURL, atomically: true, encoding: .utf8)
    }

    /// bootout (ignore failure — nothing loaded is expected) then bootstrap, so
    /// the teardown fully completes before the new job loads (no race).
    private static func reloadJob() throws {
        bootout()
        let domain = "gui/\(getuid())"
        let (status, output) = runProcess(
            "/bin/launchctl", ["bootstrap", domain, plistURL.path])
        if status != 0 {
            throw CLIError(
                command: "launchctl bootstrap", exitCode: status,
                message: output.isEmpty ? "launchctl bootstrap failed (exit \(status))." : output)
        }
    }

    private static func bootout() {
        let domain = "gui/\(getuid())"
        _ = runProcess("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
    }

    /// Runs a helper process synchronously, returning its exit code and combined
    /// output. Only used off the main thread.
    @discardableResult
    static func runProcess(_ launchPath: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "Could not launch \(launchPath): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Runs blocking work on a background queue and bridges it back to `async`.
    private func onBackground(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Scheduler.queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let queue = DispatchQueue(label: "sh.sonoscli.sonosbar.scheduler")
}
