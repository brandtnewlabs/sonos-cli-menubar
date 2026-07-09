import Foundation

// These structs mirror the JSON that `sonos ... --format json` actually emits on
// version 0.3.3 (verified against a live system). Fields are optional wherever
// the CLI might omit them (e.g. `nowPlaying` when nothing is loaded), so a
// missing key degrades to `nil` instead of failing the whole decode.

// MARK: - Speakers (`sonos discover`)

/// One row of `sonos discover --format json`:
/// `{ "ip", "name", "udn", "location" }`.
struct Speaker: Codable, Identifiable, Hashable {
    let name: String
    let ip: String
    let udn: String?
    let location: String?

    /// Stable identity for SwiftUI. Names are *not* unique (a system can have
    /// two "Sonos One" speakers), so prefer the UDN.
    var id: String { udn ?? "\(name)@\(ip)" }
}

// MARK: - Grouping (`sonos group status`)

/// `sonos group status --format json` → `{ "groups": [ ... ] }`.
struct GroupStatusResponse: Codable {
    let groups: [SpeakerGroup]
}

/// One entry of `groups`. `members` is `null` for hidden/bonded coordinators
/// (e.g. a surround setup's satellite), hence optional.
struct SpeakerGroup: Codable, Identifiable, Hashable {
    let id: String
    let coordinator: GroupMember
    let members: [GroupMember]?
}

/// A speaker as it appears inside a group's `coordinator`/`members`.
struct GroupMember: Codable, Hashable {
    let name: String
    let ip: String?
    let uuid: String?
    let location: String?
    let isVisible: Bool?
    let isCoordinator: Bool?
}

extension SpeakerGroup {
    /// Visible member names (satellites of a bonded set report `isVisible:false`
    /// and are filtered out). Always includes the coordinator.
    var visibleMemberNames: [String] {
        let members = members ?? [coordinator]
        return members
            .filter { $0.isVisible ?? true }
            .map { $0.name }
    }

    func contains(roomNamed name: String) -> Bool {
        visibleMemberNames.contains(name)
    }
}

// MARK: - Playback (`sonos status`)

/// `sonos status --name "<Room>" --format json`. The CLI reports volume/mute for
/// the queried device inline, alongside transport and now-playing metadata.
struct PlaybackStatus: Codable {
    let device: DeviceInfo?
    let transport: TransportInfo?
    let position: PositionInfo?
    let nowPlaying: NowPlaying?
    let albumArtURL: String?
    let volume: Int?
    let mute: Bool?

    struct DeviceInfo: Codable, Hashable {
        let name: String?
        let ip: String?
        let udn: String?
    }

    struct TransportInfo: Codable, Hashable {
        let state: String?
        let status: String?
        let speed: String?

        enum CodingKeys: String, CodingKey {
            case state = "State"
            case status = "Status"
            case speed = "Speed"
        }
    }

    struct PositionInfo: Codable, Hashable {
        let track: String?
        let trackDuration: String?
        let relTime: String?

        enum CodingKeys: String, CodingKey {
            case track = "Track"
            case trackDuration = "TrackDuration"
            case relTime = "RelTime"
        }
    }

    struct NowPlaying: Codable, Hashable {
        let id: String?
        let title: String?
        let uri: String?
        let artist: String?
        let album: String?
        let albumArtURI: String?
    }
}

extension PlaybackStatus {
    /// Raw transport state, e.g. `PLAYING`, `PAUSED_PLAYBACK`, `STOPPED`,
    /// `TRANSITIONING`. Falls back to `UNKNOWN` — which the UI treats as "not
    /// playing" so the play/pause icon has a definite state.
    var transportState: String { transport?.state ?? "UNKNOWN" }

    var isPlaying: Bool { transportState == "PLAYING" }

    /// Track title, or `nil` when nothing is loaded.
    var title: String? {
        let value = nowPlaying?.title
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// "Artist — Album" from whichever parts are present.
    var subtitle: String? {
        let parts = [nowPlaying?.artist, nowPlaying?.album]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    var positionSeconds: Int? { TimeCode.parse(position?.relTime) }
    var durationSeconds: Int? { TimeCode.parse(position?.trackDuration) }

    /// e.g. "1:23 / 3:38", or `nil` when there is no usable duration.
    var positionText: String? {
        guard let duration = durationSeconds, duration > 0 else { return nil }
        let elapsed = positionSeconds ?? 0
        return "\(TimeCode.format(elapsed)) / \(TimeCode.format(duration))"
    }

    /// 0…1 fraction for a progress bar, or `nil` when unknown.
    var progressFraction: Double? {
        guard let duration = durationSeconds, duration > 0,
              let elapsed = positionSeconds else { return nil }
        return min(1, max(0, Double(elapsed) / Double(duration)))
    }
}

// MARK: - Scenes (`sonos scene list`)

/// One row of `sonos scene list --format json`: `{ "name", "createdAt" }`.
/// Named `SonosScene` to avoid colliding with SwiftUI's `Scene` protocol.
struct SonosScene: Codable, Identifiable, Hashable {
    let name: String
    let createdAt: String?

    var id: String { name }
}

// MARK: - Volume / mute probes

/// `sonos [group] volume get --format json` → `{ "volume": <0-100> }`
/// (the non-group form also carries `coordinatorIP`, which we ignore).
struct VolumeResponse: Codable {
    let volume: Int?
}

/// `sonos [group] mute get --format json` → `{ "mute": <bool> }`.
struct MuteResponse: Codable {
    let mute: Bool?
}

// MARK: - Auto-group schedule

/// Persisted configuration for the daily auto-group job. `Equatable` so
/// `.onChange` can drive `syncSchedule()`.
struct AutoGroupConfig: Codable, Equatable {
    var enabled: Bool = false
    var hour: Int = 7
    var minute: Int = 0
    /// Target room whose group everything joins (the coordinator).
    var coordinator: String = ""
    var setVolume: Bool = false
    var volume: Int = 20
    var applyScene: Bool = false
    var sceneName: String = ""
}

// MARK: - Time helpers

/// Parses/formats Sonos "H:MM:SS" clock strings.
enum TimeCode {
    static func parse(_ string: String?) -> Int? {
        guard let string, !string.isEmpty else { return nil }
        let parts = string.split(separator: ":").map { Int($0) ?? 0 }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return nil
        }
    }

    static func format(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let h = clamped / 3600, m = (clamped % 3600) / 60, s = clamped % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
