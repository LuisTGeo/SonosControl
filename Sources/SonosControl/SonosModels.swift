import Foundation

/// A single Sonos player (a "room"/zone).
struct SonosZone: Identifiable, Hashable {
    /// The player's UUID, e.g. "RINCON_XXXXXXXX01400".
    let id: String
    /// The room name, e.g. "Living Room".
    let name: String
    /// The player's LAN IP, used as the SOAP endpoint host.
    let ip: String
    var volume: Int = 0
    var muted: Bool = false
    /// UUID of the coordinator of the group this zone currently belongs to.
    var coordinatorId: String

    /// A zone is its own group's coordinator when it leads (or is alone).
    var isCoordinator: Bool { id == coordinatorId }
}

/// What a group's coordinator is currently playing (any source — Spotify,
/// radio, etc. — Sonos reports the same metadata).
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    /// Absolute album-art URL, or nil.
    var artworkURL: URL?
    /// Playback position and track length, in seconds.
    var position: Int
    var duration: Int

    var hasTrack: Bool { !title.isEmpty }
}

/// A set of zones playing in sync. `id` is the coordinator's UUID.
struct SonosGroup: Identifiable {
    let id: String
    var members: [SonosZone]
    var isPlaying: Bool = false
    var nowPlaying: NowPlaying?

    var coordinator: SonosZone? { members.first { $0.id == id } }

    /// "Living Room", or "Living Room +2" when grouped.
    var name: String {
        let lead = coordinator?.name ?? members.first?.name ?? "Group"
        let others = members.count - 1
        return others > 0 ? "\(lead) +\(others)" : lead
    }

    /// Average member volume — a reasonable stand-in for the group level.
    var averageVolume: Int {
        guard !members.isEmpty else { return 0 }
        return members.map(\.volume).reduce(0, +) / members.count
    }
}

/// SOAP service coordinates for the endpoints we talk to (all on port 1400).
enum SonosService {
    static let rendering = (path: "/MediaRenderer/RenderingControl/Control",
                            type: "urn:schemas-upnp-org:service:RenderingControl:1")
    static let groupRendering = (path: "/MediaRenderer/GroupRenderingControl/Control",
                                 type: "urn:schemas-upnp-org:service:GroupRenderingControl:1")
    static let avTransport = (path: "/MediaRenderer/AVTransport/Control",
                              type: "urn:schemas-upnp-org:service:AVTransport:1")
    static let topology = (path: "/ZoneGroupTopology/Control",
                           type: "urn:schemas-upnp-org:service:ZoneGroupTopology:1")
}
