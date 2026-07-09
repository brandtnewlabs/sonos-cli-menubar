# SonosBar

A macOS menu bar app that controls Sonos speakers by shelling out to
[`sonoscli`](https://sonoscli.sh). It never speaks UPnP/SOAP itself — every
action maps to a `sonos` subcommand.

Features:

- **Auto-group schedule** — group every speaker to a chosen room at a set time
  each day (e.g. "everything to the Living Room at 07:00"), running via `launchd`
  even when the app is closed. Optionally set the group volume or apply a scene.
- Manual grouping (join/leave, party, solo, dissolve).
- Playback (play/pause/next/prev), group volume, and mute.
- Save, apply, and delete scenes.

## Requirements

- macOS 13 or later.
- The `sonos` binary. Install it with Homebrew:

  ```sh
  brew install steipete/tap/sonoscli
  ```

  If SonosBar can't find it, it shows a setup screen where you can point it at
  the binary directly. It looks in `/opt/homebrew/bin/sonos` and
  `/usr/local/bin/sonos` by default.

## Build & install

```sh
./Scripts/bundle.sh          # builds release + produces SonosBar.app
open SonosBar.app            # or move it to /Applications first
```

`bundle.sh` wraps the SwiftPM binary in a proper `.app` with `LSUIElement` set,
so it lives only in the menu bar (no Dock icon). To iterate during development
you can also just `swift run`, but the bundled app avoids known `MenuBarExtra`
focus quirks.

Look for the speaker icon in the menu bar; click it to open the popover.

## Two caveats for the scheduled auto-group

The schedule fires through a `launchd` calendar job. Two things about it are
worth understanding — the app surfaces both next to the time picker.

### 1. Local Network permission (important)

On macOS 15+ (Sequoia and later), reaching devices on your LAN requires the
**Local Network** privilege, granted per app. The scheduled job runs
**SonosBar's own binary** (`SonosBar --run-autogroup`) rather than a bare shell
script for exactly this reason: a `launchd → /bin/zsh → sonos` job has no stable
app identity, so macOS silently drops its traffic and the `sonos` tool reports
*"no speakers found."* Running the app binary means the scheduled run shares the
grant the GUI already holds.

So: **grant SonosBar Local Network access once.** The easiest way is to press
**Test now** in the schedule section — that triggers the system prompt. Or enable
it under *System Settings ▸ Privacy & Security ▸ Local Network*. Until you do,
scheduled runs (and discovery in general) will find no speakers.

Note: ad-hoc–signed local builds get a new code identity each time you rebuild,
which can reset this grant. A `Developer ID`–signed build keeps it stable.

### 2. Sleep

**If your Mac is asleep at the scheduled time, macOS does not wake it — the job
runs on the next wake.** For an exact time, add a wake schedule:

```sh
sudo pmset repeat wake MTWRFSU 06:55:00
```

## Where things live

The schedule is a LaunchAgent that runs the app binary headlessly:

| Path | What |
| --- | --- |
| `~/Library/LaunchAgents/sh.sonoscli.sonosbar.autogroup.plist` | The launchd job (`SonosBar --run-autogroup`) |
| `~/Library/Application Support/SonosBar/autogroup.log` | Run log (scheduled runs and "Test now") |

Toggling the schedule off removes the job and the plist. You can inspect a
loaded job with:

```sh
launchctl print gui/$(id -u)/sh.sonoscli.sonosbar.autogroup
```

Preferences (binary path, selected room, schedule config) are stored in
`UserDefaults` under the `sh.sonoscli.sonosbar` domain.

## How it maps to the CLI

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

## Notes & limitations

- Actions target the **group coordinator** of the selected room.
- Speaker names are used as identifiers throughout (that's how `sonos` targets a
  device). A system with two identically named speakers is inherently ambiguous
  to the CLI; the room picker de-duplicates by name.
- Polling for now-playing status happens only while the popover is open — each
  call is a process spawn. Event streaming (`sonos watch`) is a future upgrade.

## License

MIT — see [LICENSE](LICENSE).
