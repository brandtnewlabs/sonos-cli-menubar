import SwiftUI

/// The popover contents. A single scroll column ~340pt wide. When the binary is
/// missing, everything below the setup view is pointless, so we render only that.
struct MenuView: View {
    @EnvironmentObject private var store: SonosStore

    var body: some View {
        Group {
            if store.binaryAvailable {
                mainContent
            } else {
                SetupView()
            }
        }
        .frame(width: 340)
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RoomPickerSection()
                Divider()
                NowPlayingSection()
                TransportSection()
                VolumeSection()
                Divider()
                GroupingSection()
                Divider()
                ScenesSection()
                Divider()
                ScheduleSection()
                Divider()
                FooterSection()
            }
            .padding(14)
        }
        .frame(maxHeight: 560)
        .task {
            await store.reconcileScheduleOnce()
            await store.refreshAll()
            store.startPolling()
        }
        .onDisappear { store.stopPolling() }
    }
}

// MARK: - Shared bits

/// A caption-styled section label.
private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// A button whose action is async. While the action is in flight it swaps its
/// label for a spinner — keeping the same footprint so the layout doesn't jump —
/// and disables itself. Every action that spawns a `sonos` process gets its own
/// immediate feedback, rather than only the global footer indicator.
private struct AsyncButton<Label: View>: View {
    let action: () async -> Void
    @ViewBuilder var label: () -> Label

    @State private var running = false

    var body: some View {
        Button {
            guard !running else { return }
            running = true
            Task {
                await action()
                running = false
            }
        } label: {
            label()
                .opacity(running ? 0 : 1)
                .overlay(alignment: .center) {
                    if running {
                        ProgressView().controlSize(.small)
                    }
                }
        }
        .disabled(running)
    }
}

extension AsyncButton where Label == Text {
    init(_ title: String, action: @escaping () async -> Void) {
        self.init(action: action) { Text(title) }
    }
}

// MARK: - 1. Missing binary

private struct SetupView: View {
    @EnvironmentObject private var store: SonosStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("sonos not found", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("SonosBar drives the `sonos` command-line tool. Install it with Homebrew:")
                .font(.callout)

            Text("brew install steipete/tap/sonoscli")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Text("Or point SonosBar at the binary:")
                .font(.callout)
            TextField("/opt/homebrew/bin/sonos", text: $store.binaryPath)
                .textFieldStyle(.roundedBorder)

            if !store.binaryPath.isEmpty && !store.binaryAvailable {
                Text("No executable at that path.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
    }
}

// MARK: - 2. Room picker

private struct RoomPickerSection: View {
    @EnvironmentObject private var store: SonosStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("Room")
            if store.rooms.isEmpty {
                Text(store.busy ? "Discovering…" : "No speakers found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Room", selection: roomBinding) {
                    ForEach(store.rooms) { speaker in
                        Text(speaker.name).tag(speaker.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var roomBinding: Binding<String> {
        Binding(get: { store.selectedRoom }, set: { store.selectRoom($0) })
    }
}

// MARK: - 3. Now playing

private struct NowPlayingSection: View {
    @EnvironmentObject private var store: SonosStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let status = store.status, let title = status.title {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle = status.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let position = status.positionText {
                    Text(position)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing playing")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 4. Transport

private struct TransportSection: View {
    @EnvironmentObject private var store: SonosStore

    var body: some View {
        HStack(spacing: 28) {
            Spacer()
            transportButton("backward.fill") { await store.transport("prev") }
            transportButton(playPauseIcon, size: 26) { await store.playPause() }
            transportButton("forward.fill") { await store.transport("next") }
            Spacer()
        }
    }

    private var playPauseIcon: String {
        (store.status?.isPlaying ?? false) ? "pause.fill" : "play.fill"
    }

    private func transportButton(
        _ systemName: String, size: CGFloat = 18, action: @escaping () async -> Void
    ) -> some View {
        AsyncButton(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(store.selectedRoom.isEmpty)
    }
}

// MARK: - 5. Volume

private struct VolumeSection: View {
    @EnvironmentObject private var store: SonosStore
    @State private var volume: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            AsyncButton {
                await store.toggleMute()
            } label: {
                Image(systemName: muteIcon)
                    .font(.system(size: 15))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)

            Slider(value: $volume, in: 0...100) { editing in
                if !editing { Task { await store.setGroupVolume(Int(volume.rounded())) } }
            }

            Text("\(Int(volume.rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 26, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .disabled(store.selectedRoom.isEmpty)
        // Keep the slider in step with polled status without an `onChange`.
        .task(id: store.status?.volume) {
            if let current = store.status?.volume {
                volume = Double(current)
            }
        }
    }

    private var muteIcon: String {
        (store.status?.mute ?? false) ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }
}

// MARK: - 6. Grouping

private struct GroupingSection: View {
    @EnvironmentObject private var store: SonosStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Grouping")

            ForEach(store.rooms) { room in
                GroupingRow(roomName: room.name)
            }

            HStack {
                AsyncButton("Party") { await store.partyMode() }
                AsyncButton("Solo") { await store.solo() }
                AsyncButton("Dissolve") { await store.dissolve() }
            }
            .controlSize(.small)
        }
    }
}

/// One grouping checkbox with its own in-flight spinner — joining/leaving a
/// group is a `sonos` round-trip, so the row shows progress until it settles.
private struct GroupingRow: View {
    @EnvironmentObject private var store: SonosStore
    let roomName: String

    @State private var running = false

    private var isCoordinator: Bool { roomName == store.coordinatorName }

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: binding) {
                HStack(spacing: 6) {
                    Text(roomName)
                    if isCoordinator {
                        Text("coordinator")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(isCoordinator || running)

            if running {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { store.isMember(roomName) },
            set: { _ in
                guard !running else { return }
                running = true
                Task {
                    await store.toggleMembership(roomName)
                    running = false
                }
            }
        )
    }
}

// MARK: - 7. Scenes

private struct ScenesSection: View {
    @EnvironmentObject private var store: SonosStore
    @State private var newSceneName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Scenes")

            if store.scenes.isEmpty {
                Text("No saved scenes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.scenes) { scene in
                    HStack {
                        AsyncButton(scene.name) { await store.applyScene(scene.name) }
                            .buttonStyle(.plain)
                        Spacer()
                        AsyncButton {
                            await store.deleteScene(scene.name)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                TextField("New scene from current state", text: $newSceneName)
                    .textFieldStyle(.roundedBorder)
                AsyncButton("Save") {
                    await store.saveScene(newSceneName)
                    newSceneName = ""
                }
                .disabled(newSceneName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - 8. Auto-group schedule

private struct ScheduleSection: View {
    @EnvironmentObject private var store: SonosStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Auto-group schedule")

            Toggle("Group speakers on a daily schedule", isOn: enabledBinding)

            if store.autoGroup.enabled {
                scheduleControls
            }
        }
    }

    @ViewBuilder private var scheduleControls: some View {
        HStack {
            DatePicker("At", selection: syncing(timeBinding), displayedComponents: .hourAndMinute)
                .labelsHidden()
            Picker("Group everyone to", selection: syncing($store.autoGroup.coordinator)) {
                ForEach(store.rooms) { room in
                    Text(room.name).tag(room.name)
                }
            }
        }

        Toggle("Set group volume", isOn: syncing($store.autoGroup.setVolume))
        if store.autoGroup.setVolume {
            Stepper("Volume: \(store.autoGroup.volume)",
                    value: syncing($store.autoGroup.volume), in: 0...100, step: 5)
        }

        Toggle("Apply a scene instead", isOn: syncing($store.autoGroup.applyScene))
            .disabled(store.scenes.isEmpty)
        if store.autoGroup.applyScene && !store.scenes.isEmpty {
            Picker("Scene", selection: syncing($store.autoGroup.sceneName)) {
                ForEach(store.scenes) { scene in
                    Text(scene.name).tag(scene.name)
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Grant SonosBar **Local Network** access (System Settings ▸ Privacy & Security ▸ Local Network). Without it, the scheduled run can't reach your speakers. Use “Test now” once to trigger the prompt.")
            } icon: {
                Image(systemName: "network")
            }
            Label {
                Text("If the Mac is asleep at this time, macOS won't wake it — the job runs on next wake. For an exact time, set a wake schedule, e.g. `pmset repeat wake MTWRFSU 06:55:00`.")
            } icon: {
                Image(systemName: "moon.zzz")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        HStack {
            AsyncButton("Test now") { await store.testSchedule() }
                .controlSize(.small)
            Spacer()
        }
    }

    // MARK: Bindings

    /// Toggling on with no coordinator chosen defaults it to the current room.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.autoGroup.enabled },
            set: { newValue in
                if newValue && store.autoGroup.coordinator.isEmpty {
                    store.autoGroup.coordinator = store.selectedRoom
                }
                store.autoGroup.enabled = newValue
                Task { await store.syncSchedule() }
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = store.autoGroup.hour
                components.minute = store.autoGroup.minute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                store.autoGroup.hour = components.hour ?? 0
                store.autoGroup.minute = components.minute ?? 0
            }
        )
    }

    /// Wraps a binding so any change also reconciles the launchd job. Replaces
    /// `.onChange(of: autoGroup)` and fires only on real edits.
    private func syncing<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                Task { await store.syncSchedule() }
            }
        )
    }
}

// MARK: - 9. Footer

private struct FooterSection: View {
    @EnvironmentObject private var store: SonosStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = store.lastError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        store.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                if store.busy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                AsyncButton {
                    await store.refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}
