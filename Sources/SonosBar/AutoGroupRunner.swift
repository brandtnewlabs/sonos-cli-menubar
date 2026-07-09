import Foundation

/// Executes the auto-group action. This is the single implementation shared by
/// two callers:
///
///  - the **scheduled run** — launchd starts `SonosBar --run-autogroup`, which
///    calls `runHeadlessAndExit()`. Because launchd runs the *app's own signed
///    binary*, the sonos subprocess inherits SonosBar's Local Network (TCC)
///    grant. A plain `/bin/zsh → sonos` LaunchAgent cannot: modern macOS
///    silently drops all local-network traffic from a background agent that has
///    no Local Network permission, so discovery returns "no speakers found".
///
///  - the **"Test now"** button — the running GUI app calls `execute` directly
///    (it already holds the Local Network grant).
///
/// Room names reach `sonos` as argv, never through a shell, so apostrophes and
/// other shell-significant characters need no quoting.
enum AutoGroupRunner {

    struct StepResult {
        let description: String
        let error: String?
        var ok: Bool { error == nil }
    }

    /// Runs the configured actions and returns a per-step result list.
    static func execute(config: AutoGroupConfig, binaryPath: String) -> [StepResult] {
        let cli = SonosCLI(binaryPath: binaryPath)
        var results: [StepResult] = []

        func run(_ description: String, _ arguments: [String]) {
            do {
                try cli.runBlocking(arguments)
                results.append(StepResult(description: description, error: nil))
            } catch {
                let message = (error as? CLIError)?.errorDescription ?? error.localizedDescription
                results.append(StepResult(description: description, error: message))
            }
        }

        let scene = config.sceneName.trimmingCharacters(in: .whitespaces)
        let coordinator = config.coordinator.trimmingCharacters(in: .whitespaces)

        if config.applyScene, !scene.isEmpty {
            run("apply scene \"\(scene)\"", ["scene", "apply", scene])
        } else if !coordinator.isEmpty {
            run("party → \(coordinator)", ["group", "party", "--to", coordinator])
            if config.setVolume {
                run("group volume \(config.volume)",
                    ["group", "volume", "set", "--name", coordinator, String(config.volume)])
            }
        } else {
            results.append(StepResult(description: "nothing configured", error: "no coordinator or scene set"))
        }
        return results
    }

    /// Async wrapper so the GUI's "Test now" doesn't block the main thread.
    static func executeAsync(config: AutoGroupConfig, binaryPath: String) async -> [StepResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: execute(config: config, binaryPath: binaryPath))
            }
        }
    }

    /// Renders a log block for one run.
    static func logBlock(_ results: [StepResult], source: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["===== \(formatter.string(from: Date())) SonosBar auto-group (\(source)) ====="]
        for result in results {
            lines.append(result.ok ? "  ok:     \(result.description)"
                                   : "  FAILED: \(result.description): \(result.error ?? "")")
        }
        lines.append("----- done -----")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends a block to the shared auto-group log.
    static func appendLog(_ block: String) {
        let url = Scheduler.logURL
        try? FileManager.default.createDirectory(
            at: Scheduler.supportDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = block.data(using: .utf8) { try? handle.write(contentsOf: data) }
        } else {
            try? block.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Entry point for `SonosBar --run-autogroup`, invoked by launchd. Reads the
    /// persisted config, runs it, appends to the log, and exits.
    static func runHeadlessAndExit() -> Never {
        let defaults = UserDefaults.standard
        let binaryPath = defaults.string(forKey: "binaryPath") ?? SonosCLI.defaultPath

        var config = AutoGroupConfig()
        if let data = defaults.data(forKey: "autoGroup"),
           let decoded = try? JSONDecoder().decode(AutoGroupConfig.self, from: data) {
            config = decoded
        }

        let results = execute(config: config, binaryPath: binaryPath)
        appendLog(logBlock(results, source: "scheduled"))
        exit(results.allSatisfy { $0.ok } ? 0 : 1)
    }
}
