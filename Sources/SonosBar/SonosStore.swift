import Foundation
import SwiftUI

/// All app state and every action, isolated to the main actor. UI reads the
/// `@Published` values; actions shell out through `SonosCLI` (which hops to a
/// background queue) and refresh the affected slice of state.
@MainActor
final class SonosStore: ObservableObject {

    // MARK: Published state

    @Published var speakers: [Speaker] = []
    @Published var groups: [SpeakerGroup] = []
    @Published var status: PlaybackStatus?
    @Published var scenes: [SonosScene] = []

    /// Room whose group every transport/volume action targets.
    @Published var selectedRoom: String = ""
    @Published var autoGroup = AutoGroupConfig()

    @Published var binaryAvailable: Bool = false
    @Published var busy: Bool = false
    @Published var lastError: String?

    /// Path to the `sonos` binary. Editing it re-checks availability and persists.
    @Published var binaryPath: String {
        didSet {
            defaults.set(binaryPath, forKey: Keys.binaryPath)
            binaryAvailable = SonosCLI(binaryPath: binaryPath).isAvailable
        }
    }

    // MARK: Derived

    private var cli: SonosCLI { SonosCLI(binaryPath: binaryPath) }
    private var scheduler: Scheduler { Scheduler() }

    /// Speakers deduplicated by name — Picker tags and grouping rows must be
    /// unique, and a system can legitimately have two identically named units.
    var rooms: [Speaker] {
        var seen = Set<String>()
        return speakers.filter { seen.insert($0.name).inserted }
    }

    /// The group the selected room currently belongs to.
    var selectedGroup: SpeakerGroup? {
        groups.first { $0.contains(roomNamed: selectedRoom) }
    }

    /// Coordinator of the selected room's group — the target for group volume,
    /// mute, party, and join. Falls back to the room itself when standalone or
    /// not yet in any known group.
    var coordinatorName: String {
        selectedGroup?.coordinator.name ?? selectedRoom
    }

    func isMember(_ roomName: String) -> Bool {
        selectedGroup?.contains(roomNamed: roomName) ?? (roomName == selectedRoom)
    }

    // MARK: Persistence

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let binaryPath = "binaryPath"
        static let selectedRoom = "selectedRoom"
        static let autoGroup = "autoGroup"
    }

    init() {
        let savedPath = defaults.string(forKey: Keys.binaryPath) ?? SonosCLI.defaultPath
        self.binaryPath = savedPath
        self.binaryAvailable = SonosCLI(binaryPath: savedPath).isAvailable
        self.selectedRoom = defaults.string(forKey: Keys.selectedRoom) ?? ""
        if let data = defaults.data(forKey: Keys.autoGroup),
           let config = try? JSONDecoder().decode(AutoGroupConfig.self, from: data) {
            self.autoGroup = config
        }
    }

    // MARK: Refresh

    /// Discovery + topology + scenes concurrently, then now-playing for the
    /// selected room. Called once when the popover first appears.
    func refreshAll() async {
        guard binaryAvailable else { return }
        beginWork()
        defer { endWork() }
        do {
            async let speakersFetch = cli.runJSON([Speaker].self, ["discover"])
            async let groupsFetch = cli.runJSON(GroupStatusResponse.self, ["group", "status"])
            async let scenesFetch = cli.runJSON([SonosScene].self, ["scene", "list"])
            let (discovered, groupResponse, sceneList) = try await (speakersFetch, groupsFetch, scenesFetch)
            speakers = discovered.sorted { $0.name < $1.name }
            groups = groupResponse.groups
            scenes = sceneList
            reconcileSelectedRoom()
        } catch {
            report(error)
        }
        await refreshStatus()
    }

    /// Refreshes the state that can change out from under the open popover:
    /// group topology *and* now-playing status. Grouping can change from the
    /// scheduled job, "Test now", or the Sonos app itself, so the poll must
    /// re-fetch groups — not just status.
    func refreshLive() async {
        await refreshGroups()
        await refreshStatus()
    }

    /// Now-playing + volume/mute for the selected room. Cheap enough to poll.
    func refreshStatus() async {
        guard binaryAvailable, !selectedRoom.isEmpty else { return }
        do {
            status = try await cli.runJSON(PlaybackStatus.self, ["status", "--name", selectedRoom])
        } catch {
            report(error)
        }
    }

    private func refreshGroups() async {
        guard binaryAvailable else { return }
        do {
            groups = try await cli.runJSON(GroupStatusResponse.self, ["group", "status"]).groups
        } catch {
            report(error)
        }
    }

    /// Grouping and scene changes take a moment to propagate across Sonos before
    /// `group status` reflects them. Wait briefly, then refresh the live view so
    /// the checkboxes update immediately rather than on the next poll.
    private func settleAndRefresh() async {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await refreshLive()
    }

    private func refreshScenes() async {
        guard binaryAvailable else { return }
        do {
            scenes = try await cli.runJSON([SonosScene].self, ["scene", "list"])
        } catch {
            report(error)
        }
    }

    private func reconcileSelectedRoom() {
        let names = rooms.map(\.name)
        if selectedRoom.isEmpty || !names.contains(selectedRoom) {
            selectedRoom = names.first ?? ""
        }
    }

    /// User-initiated room change (Picker). Distinct from the programmatic
    /// assignment in `refreshAll`, so switching rooms fetches status exactly
    /// once — no redundant round-trip.
    func selectRoom(_ name: String) {
        guard name != selectedRoom else { return }
        selectedRoom = name
        defaults.set(name, forKey: Keys.selectedRoom)
        Task { await refreshStatus() }
    }

    // MARK: Transport

    func playPause() async {
        let action = (status?.isPlaying ?? false) ? "pause" : "play"
        await transport(action)
    }

    func transport(_ action: String) async {
        await perform { try await self.cli.run([action, "--name", self.selectedRoom]) }
        await refreshStatus()
    }

    // MARK: Volume / mute

    /// Sets the *group* volume on the coordinator. Called on slider release, not
    /// per-pixel — each call is a process spawn.
    func setGroupVolume(_ volume: Int) async {
        let clamped = min(100, max(0, volume))
        await perform {
            try await self.cli.run(
                ["group", "volume", "set", "--name", self.coordinatorName, String(clamped)])
        }
    }

    func toggleMute() async {
        await perform {
            try await self.cli.run(["group", "mute", "toggle", "--name", self.coordinatorName])
        }
        await refreshStatus()
    }

    // MARK: Grouping

    /// Join `roomName` to the selected group, or remove it if already a member.
    func toggleMembership(_ roomName: String) async {
        guard roomName != coordinatorName else { return }  // coordinator is the anchor
        let joining = !isMember(roomName)
        await perform {
            if joining {
                try await self.cli.run(["group", "join", "--name", roomName, "--to", self.coordinatorName])
            } else {
                try await self.cli.run(["group", "unjoin", "--name", roomName])
            }
        }
        await settleAndRefresh()
    }

    func partyMode() async {
        await perform {
            try await self.cli.run(["group", "party", "--to", self.coordinatorName])
        }
        await settleAndRefresh()
    }

    func solo() async {
        await perform { try await self.cli.run(["group", "solo", "--name", self.selectedRoom]) }
        await settleAndRefresh()
    }

    func dissolve() async {
        await perform { try await self.cli.run(["group", "dissolve", "--name", self.selectedRoom]) }
        await settleAndRefresh()
    }

    // MARK: Scenes

    func applyScene(_ name: String) async {
        await perform { try await self.cli.run(["scene", "apply", name]) }
        // Applying a scene changes grouping and volumes.
        await settleAndRefresh()
    }

    func saveScene(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await perform { try await self.cli.run(["scene", "save", trimmed]) }
        await refreshScenes()
    }

    func deleteScene(_ name: String) async {
        await perform { try await self.cli.run(["scene", "delete", name]) }
        await refreshScenes()
    }

    // MARK: Auto-group schedule

    /// Persist `autoGroup` and reconcile the launchd job to match. Wired to
    /// every change of `autoGroup` from the UI.
    func syncSchedule() async {
        persistAutoGroup()
        await perform {
            if self.autoGroup.enabled {
                try await self.scheduler.install(self.autoGroup)
            } else {
                try await self.scheduler.uninstall()
            }
        }
    }

    private var hasReconciled = false

    /// Reconciles the launchd job at most once per app run (on first popover
    /// appearance) so repeatedly opening the menu doesn't reload the job.
    func reconcileScheduleOnce() async {
        guard !hasReconciled else { return }
        hasReconciled = true
        await reconcileSchedule()
    }

    /// Make the on-disk job match the saved config (it may have been removed, or
    /// the binary path may have changed since last run).
    func reconcileSchedule() async {
        if autoGroup.enabled {
            await perform { try await self.scheduler.install(self.autoGroup) }
        } else if scheduler.isInstalled {
            await perform { try await self.scheduler.uninstall() }
        }
    }

    /// Runs the auto-group action immediately, in-process (the GUI holds the
    /// Local Network grant), using the exact same code the scheduled job runs.
    /// Writes to the same log, then refreshes topology.
    func testSchedule() async {
        guard binaryAvailable else { return }
        beginWork()
        let results = await AutoGroupRunner.executeAsync(config: autoGroup, binaryPath: binaryPath)
        AutoGroupRunner.appendLog(AutoGroupRunner.logBlock(results, source: "test"))
        if let failure = results.first(where: { !$0.ok }) {
            lastError = "Auto-group test: \(failure.description) — \(failure.error ?? "")"
        }
        endWork()
        await settleAndRefresh()
    }

    private func persistAutoGroup() {
        if let data = try? JSONEncoder().encode(autoGroup) {
            defaults.set(data, forKey: Keys.autoGroup)
        }
    }

    // MARK: Polling (popover-open only)

    private var pollingTask: Task<Void, Never>?

    func startPolling() {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshLive()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: Error / busy plumbing

    func dismissError() { lastError = nil }

    private var busyCount = 0

    private func beginWork() {
        busyCount += 1
        busy = true
    }

    private func endWork() {
        busyCount = max(0, busyCount - 1)
        busy = busyCount > 0
    }

    /// Runs an action with busy tracking and unified error reporting.
    private func perform(_ body: () async throws -> Void) async {
        guard binaryAvailable else { return }
        beginWork()
        defer { endWork() }
        do {
            try await body()
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        if let cliError = error as? CLIError {
            lastError = cliError.errorDescription
        } else {
            lastError = error.localizedDescription
        }
    }
}
