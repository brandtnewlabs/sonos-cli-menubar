# SonosBar — Implementation Plan

A macOS menu bar app that wraps [`sonoscli`](https://sonoscli.sh), with an
auto-group schedule (e.g. "group every speaker to Living Room at 07:00") plus
manual grouping, playback/volume, and scenes.

The app **shells out to the `sonos` binary**. It never speaks UPnP/SOAP itself.
Every feature must map to a documented subcommand.

---

## 1. Current state

Partial implementation exists in this directory. Treat it as a starting point,
not as verified code — **none of it has been compiled.** It was written in a
Linux sandbox with no Swift/macOS toolchain.

| File | Status |
| --- | --- |
| `Package.swift` | Written. SwiftPM executable, `macOS(.v13)`. |
| `Sources/SonosBar/JSONValue.swift` | Written. Permissive JSON tree. |
| `Sources/SonosBar/SonosCLI.swift` | Written. `Process` wrapper, concurrent pipe drain. |
| `Sources/SonosBar/Models.swift` | Written. `Speaker`, `SpeakerGroup`, `PlaybackStatus`, `AutoGroupConfig`. |
| `Sources/SonosBar/Scheduler.swift` | Written. Generates a shell script + LaunchAgent plist. |
| `Sources/SonosBar/SonosStore.swift` | Written. `@MainActor ObservableObject`, all CLI actions. |
| `Sources/SonosBar/MenuView.swift` | **Missing.** |
| `Sources/SonosBar/SonosBarApp.swift` | **Missing.** |
| `Scripts/bundle.sh` | **Missing.** |
| `README.md` | **Missing.** |

**First task for the implementing agent: run `swift build` and fix whatever
breaks.** Expect errors. Known suspect areas are listed in §6.

---

## 2. Constraints that drove the design

**Undocumented JSON shapes.** sonoscli's docs promise `--format json` with
"stable keys" but only actually show `.[].name`, `.[].ip`, `.[].model`,
`.track.title`, and `.transport_state`. The shapes of `group status`,
`scene list`, `volume get`, and `mute get` are unspecified. Hence `JSONValue`
plus candidate-key lookup (`json.any("coordinator", "coordinatorName", …)`)
rather than rigid `Codable` structs.

> **Before writing UI, run each command against a real system and record the
> actual output.** Then either narrow the candidate lists or, better, replace
> `JSONValue` with real `Codable` structs. The permissive layer is scaffolding
> for the unknown, not a design goal.
>
> ```bash
> sonos discover     --format json
> sonos group status --format json
> sonos scene list   --format json
> sonos status       --format json --name "<Room>"
> ```

**launchd, not a background daemon.** The schedule must fire when the app isn't
running. `Scheduler` writes `~/Library/Application Support/SonosBar/autogroup.sh`
and registers `~/Library/LaunchAgents/sh.sonoscli.sonosbar.autogroup.plist`.
A script (rather than invoking `sonos` directly) lets one job do several things:
party-mode, then set volume, then optionally apply a scene.

**Sleep caveat — surface this in the UI.** If the Mac is asleep at 07:00,
launchd does *not* wake it; the job runs on next wake. Either the user sets a
wake schedule (`pmset repeat wake MTWRFSU 06:55:00`) or accepts the drift. The
UI should say so plainly next to the time picker, not bury it in a README.

**SwiftPM produces a bare binary, not an `.app`.** Without an `Info.plist`
carrying `LSUIElement`, the process will claim a Dock icon. Two mitigations,
both needed: an `AppDelegate` that calls `NSApp.setActivationPolicy(.accessory)`,
and a `bundle.sh` that wraps the binary into a proper `.app`.

---

## 3. Remaining work

### 3.1 `SonosBarApp.swift`

```swift
@main
struct SonosBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SonosStore()

    var body: some Scene {
        MenuBarExtra("SonosBar", systemImage: "hifispeaker.2.fill") {
            MenuView().environmentObject(store)
        }
        .menuBarExtraStyle(.window)   // required — .menu can't host sliders/pickers
    }
}
```

- `AppDelegate.applicationDidFinishLaunching` → `NSApp.setActivationPolicy(.accessory)`.
- On first appearance: `store.reconcileSchedule()` then `await store.refreshAll()`.
- Poll `refreshStatus()` on a timer (~5s) **only while the popover is open**.
  Do not poll when closed — each call is a process spawn. `sonos watch` is the
  right long-term answer (see §7).

### 3.2 `MenuView.swift`

`ScrollView`, width 340, `maxHeight` ~560. Sections, top to bottom:

1. **Missing-binary state.** If `!store.binaryAvailable`, render *only* a setup
   view: explanation, `brew install steipete/tap/sonoscli`, and a `TextField`
   bound to `store.binaryPath`. Everything below is pointless without it.

2. **Room picker.** `Picker` over `store.speakers`, bound to `store.selectedRoom`.
   All transport/volume actions target this room's group coordinator.

3. **Now playing.** From `store.status`: `title`, `subtitle` (artist — album),
   `position / duration`, transport state. Placeholder row when `status == nil`.

4. **Transport.** Buttons → `store.transport("prev")`, `store.playPause()`,
   `store.transport("next")`. Icon reflects `status?.isPlaying`.

5. **Volume.** `Slider` 0…100 bound to local `@State`, committed to
   `store.setGroupVolume(_:)` on `onEditingChanged: { if !$0 { commit() } }`.
   Do **not** fire per-pixel — that's one `Process` spawn per frame. Mute button
   → `store.toggleMute()`.

6. **Grouping.** For each speaker: a checkbox showing membership in
   `store.selectedGroup`, toggling `store.toggleMembership(_:)`. The selected
   room itself is disabled (it's the coordinator). Below: `Party` →
   `store.partyMode()`, `Solo` → `store.solo()`, `Dissolve` → `store.dissolve()`.

7. **Scenes.** List `store.scenes`; tap applies. Trailing delete button per row.
   `TextField` + `Save` → `store.saveScene(_:)`.

8. **Auto-group schedule.** The headline feature.
   - `Toggle` bound to `store.autoGroup.enabled`
   - `DatePicker(… displayedComponents: .hourAndMinute)` — bridge to
     `autoGroup.hour`/`.minute` via a computed `Binding<Date>` using
     `Calendar.current.dateComponents`/`date(from:)`
   - `Picker` for `autoGroup.coordinator` over `store.speakers`
   - `Toggle` "Set group volume to" + `Stepper`/`Slider` → `.setVolume`, `.volume`
   - `Toggle` "Apply scene instead" + `Picker` over `store.scenes` → `.applyScene`, `.sceneName`
   - Footnote: the sleep caveat from §2
   - "Test now" button → `store.testSchedule()`
   - **Every change to `store.autoGroup` must call `store.syncSchedule()`** —
     use `.onChange(of: store.autoGroup) { _ in store.syncSchedule() }`
     (`AutoGroupConfig` is already `Equatable`).

9. **Footer.** Error row (`store.lastError`, red, dismissible), `ProgressView`
   when `store.busy`, Refresh button, Quit button.

### 3.3 `Scripts/bundle.sh`

```
swift build -c release
```
then assemble `SonosBar.app/Contents/{MacOS,Resources}` with an `Info.plist`
containing `CFBundleExecutable=SonosBar`, `CFBundleIdentifier=sh.sonoscli.sonosbar`,
`LSUIElement=<true/>`, `LSMinimumSystemVersion=13.0`. Optionally `codesign -s -`.

### 3.4 `README.md`

Build, install, the `sonos` binary requirement, the sleep caveat, and where the
generated script and log live (`~/Library/Application Support/SonosBar/`).

---

## 4. Command mapping (verified against the docs)

| UI action | Command |
| --- | --- |
| Discover rooms | `sonos discover --format json` |
| Group topology | `sonos group status --format json` |
| Now playing | `sonos status --name "<Room>" --format json` |
| Play / pause / next / prev | `sonos play\|pause\|next\|prev --name "<Room>"` |
| Group volume | `sonos group volume set --name "<Coord>" <0-100>` |
| Group mute | `sonos group mute toggle --name "<Coord>"` |
| Group everything | `sonos group party --to "<Coord>"` |
| Ungroup everything else | `sonos group solo --name "<Room>"` |
| Break up a group | `sonos group dissolve --name "<Room>"` |
| Add / remove a room | `sonos group join --name "<Room>" --to "<Coord>"` / `sonos group unjoin --name "<Room>"` |
| Scenes | `sonos scene list\|apply\|save\|delete` |

Exit code `0` = success, non-zero = failure, errors on stderr. `SonosCLI.run`
already maps non-zero → `CLIError` carrying stderr.

Not yet surfaced in the UI, all available in the CLI: `play-url`, `open`
(Spotify URIs), `search spotify`, `smapi`, `favorites`, `queue`, `linein`, `tv`,
`watch`. See §7.

---

## 5. Verification

Compilation is necessary but nowhere near sufficient — nearly every failure mode
here is a wrong assumption about the CLI's output, and the compiler cannot see
those.

1. `swift build 2>&1` — zero errors, then zero warnings.
2. Dump real JSON for all four read commands (§2). Diff against the candidate
   key lists in `Models.swift`. **Any field that silently resolves to `nil` is a
   bug**, not a cosmetic issue — `PlaybackStatus.transport` falling back to
   `"UNKNOWN"` will quietly break the play/pause icon.
3. Kill the `sonos` binary path (rename it) → the app must show the setup view,
   not crash or hang.
4. `sonos discover` on a system with a stereo pair → confirm bonded secondaries
   don't appear as rooms (we don't pass `--all`, so they shouldn't).
5. Schedule round-trip: enable → inspect the generated
   `~/Library/Application Support/SonosBar/autogroup.sh` and plist by hand →
   `launchctl print gui/$(id -u)/sh.sonoscli.sonosbar.autogroup` → disable →
   confirm both the job and the plist are gone.
6. Room name with an apostrophe (`Lennart's Office`) → the generated script must
   still run. `Scheduler.shellQuote` should handle it; verify, don't assume.
7. Set the schedule one minute out, watch it fire, check
   `~/Library/Application Support/SonosBar/autogroup.log`.

---

## 6. Known-suspect code (unverified)

- `SonosStore.refreshAll` uses three `async let` calls into `query`, a
  `@MainActor` generic method wrapping `Task.detached`. Plausible, but the
  actor-isolation and `Sendable` checking here is exactly the kind of thing that
  compiles in my head and not in `swiftc`.
- `JSONValue`'s `Decodable` init tries `Bool` before `Double`. Correct for
  `JSONDecoder` today; it's an ordering dependency, so leave the comment.
- `selectedRoom.didSet` spawns a `Task` calling `refreshStatus()`, and
  `refreshAll()` assigns `selectedRoom` — one redundant status fetch per refresh.
  Harmless, but tidy it up.
- `Scheduler.install` calls `bootout` before `bootstrap` and ignores the failure.
  That's intentional (nothing loaded → non-zero exit), but confirm `bootstrap`
  doesn't then race the teardown on a fast machine.
- `MenuBarExtra` + `.menuBarExtraStyle(.window)` from an unbundled SwiftPM
  binary has known focus quirks. If the popover won't dismiss or won't take key
  input, build the `.app` bundle (§3.3) before debugging anything else.

---

## 7. Deliberately out of scope (v1)

- `sonos watch` event streaming. The right fix for polling: a long-lived
  `Process` whose stdout is read line-by-line into the store. Do this once the
  polling version works, not before.
- Spotify search / `play-url` / favorites / queue browsing. Each wants real UI
  (search field, results list) and will double the surface area.
- Multiple schedules. One job, one label. Generalizing means a label per
  schedule and a list UI.
- Sparkle updates, notarization, login item registration (`SMAppService`).