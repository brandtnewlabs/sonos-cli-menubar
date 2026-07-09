import Foundation

/// An error from running the `sonos` binary: a non-zero exit code, with the
/// text the CLI wrote to stderr.
struct CLIError: Error, LocalizedError {
    let command: String
    let exitCode: Int32
    let message: String

    var errorDescription: String? {
        if message.isEmpty {
            return "`\(command)` failed (exit \(exitCode))."
        }
        return message
    }
}

/// Thin wrapper around the `sonos` binary. It never speaks UPnP/SOAP itself —
/// every method shells out and maps a non-zero exit to `CLIError`.
///
/// `run` hops onto a background queue so callers on `@MainActor` never block the
/// main thread. stdout and stderr are drained concurrently so a large write to
/// either pipe can never deadlock the child against `waitUntilExit()`.
struct SonosCLI: Sendable {
    /// Absolute path to the `sonos` executable.
    var binaryPath: String

    /// Common locations Homebrew installs the binary, tried when no explicit
    /// path has been chosen.
    static let candidatePaths = [
        "/opt/homebrew/bin/sonos",   // Apple Silicon Homebrew
        "/usr/local/bin/sonos",      // Intel Homebrew
    ]

    /// First candidate that exists, else the Apple-Silicon default so the setup
    /// view has something concrete to show.
    static var defaultPath: String {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? candidatePaths[0]
    }

    var isAvailable: Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        // `isExecutableFile` reports true for searchable directories, so exclude
        // those explicitly — a directory path must not read as "binary present".
        guard fileManager.fileExists(atPath: binaryPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: binaryPath)
    }

    // MARK: Running

    /// Runs `sonos <arguments>` and returns raw stdout on success.
    @discardableResult
    func run(_ arguments: [String]) async throws -> Data {
        let path = binaryPath
        return try await withCheckedThrowingContinuation { continuation in
            SonosCLI.workQueue.async {
                do {
                    continuation.resume(returning: try SonosCLI.runSync(path: path, arguments: arguments))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous run, for the headless auto-group runner which has no event
    /// loop to await on. Returns stdout on success, throws `CLIError` otherwise.
    @discardableResult
    func runBlocking(_ arguments: [String]) throws -> Data {
        try SonosCLI.runSync(path: binaryPath, arguments: arguments)
    }

    /// Runs `sonos <arguments> --format json` and decodes stdout as `T`.
    func runJSON<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        let data = try await run(arguments + ["--format", "json"])
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw CLIError(
                command: "sonos " + arguments.joined(separator: " "),
                exitCode: 0,
                message: "Could not decode JSON from `sonos \(arguments.joined(separator: " "))`: \(error). Output was: \(raw.prefix(200))"
            )
        }
    }

    // MARK: Background execution

    private static let workQueue = DispatchQueue(
        label: "sh.sonoscli.sonosbar.cli", attributes: .concurrent)
    private static let ioQueue = DispatchQueue(
        label: "sh.sonoscli.sonosbar.io", attributes: .concurrent)

    /// Mutable buffer shared with the stderr-drain closure. Access is ordered by
    /// a `DispatchGroup` barrier, so no internal lock is needed.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    private static func runSync(path: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CLIError(
                command: "sonos " + arguments.joined(separator: " "),
                exitCode: -1,
                message: "Could not launch \(path): \(error.localizedDescription)"
            )
        }

        // Drain stderr concurrently while we read stdout on this thread, then
        // wait for both before inspecting the exit status.
        let errBox = DataBox()
        let errHandle = errPipe.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        ioQueue.async {
            errBox.data = errHandle.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()

        let status = process.terminationStatus
        guard status == 0 else {
            let stderr = String(data: errBox.data, encoding: .utf8) ?? ""
            throw CLIError(
                command: "sonos " + arguments.joined(separator: " "),
                exitCode: status,
                message: cleanupMessage(stderr)
            )
        }
        return outData
    }

    /// Trims whitespace and a leading `Error: ` prefix from a stderr message.
    private static func cleanupMessage(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "Error: ", options: .anchored) {
            text.removeSubrange(range)
        }
        return text
    }
}
