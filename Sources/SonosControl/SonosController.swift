import Foundation
import SwiftUI

/// Orchestrates the Sonos system: discovers players, reads the current
/// zone-group topology + volumes, and issues control commands (volume, mute,
/// play/pause, grouping). Publishes `groups` for the UI to render.
@MainActor
final class SonosController: ObservableObject {
    @Published private(set) var groups: [SonosGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var status: String?

    /// IPs we've discovered; any one can serve the whole topology. Persisted so
    /// later launches skip the multicast round-trip.
    private var knownIPs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "knownSonosIPs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "knownSonosIPs") }
    }

    private var refreshTask: Task<Void, Never>?

    // MARK: - Loading

    func refresh() {
        // Coalesce rapid refreshes (e.g. reopening the panel).
        guard refreshTask == nil else { return }
        isLoading = true
        status = nil
        refreshTask = Task { [weak self] in
            await self?.load()
            self?.refreshTask = nil
        }
    }

    private func load() async {
        // Try a cached IP first; fall back to SSDP discovery.
        var deviceIP = try? await firstReachable(knownIPs)

        // SSDP multicast (fast, but often filtered on Wi-Fi).
        if deviceIP == nil {
            status = "Searching for Sonos…"
            let discovered = await Task.detached(priority: .userInitiated) {
                SonosDiscovery.discover()
            }.value
            if !discovered.isEmpty { knownIPs = discovered }
            deviceIP = discovered.first
        }

        // Direct subnet scan (reliable when multicast is blocked; also triggers
        // the macOS Local Network prompt via unicast requests).
        if deviceIP == nil {
            status = "Scanning local network…"
            let scanned = await SonosDiscovery.scanSubnets()
            if !scanned.isEmpty { knownIPs = scanned }
            deviceIP = scanned.first
        }

        guard let ip = deviceIP else {
            status = "No Sonos found on this network"
            groups = []
            isLoading = false
            return
        }

        do {
            let response = try await SoapClient.send(
                ip: ip, service: SonosService.topology, action: "GetZoneGroupState"
            )
            let topo = ZoneGroupTopology.parse(response)
            groups = topo
                .map { group in
                    SonosGroup(
                        id: group.coordinator,
                        members: group.members.map {
                            SonosZone(id: $0.uuid, name: $0.name, ip: $0.ip, coordinatorId: group.coordinator)
                        }
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            status = groups.isEmpty ? "No rooms reported" : nil
            await refreshVolumes()
            await refreshPlayState()
            await refreshNowPlaying()
        } catch {
            status = "Couldn't reach Sonos (\(ip))"
        }
        isLoading = false
    }

    /// Adds a speaker by IP (e.g. from the Sonos app → Settings → System → About)
    /// for networks where discovery is blocked, then reloads.
    func addManualIP(_ raw: String) {
        let ip = raw.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        var ips = knownIPs
        if !ips.contains(ip) { ips.insert(ip, at: 0) }
        knownIPs = ips
        refresh()
    }

    /// Returns the first IP that answers a lightweight request, or nil.
    private func firstReachable(_ ips: [String]) async throws -> String? {
        for ip in ips {
            if (try? await SoapClient.send(ip: ip, service: SonosService.topology, action: "GetZoneGroupState")) != nil {
                return ip
            }
        }
        return nil
    }

    private func refreshVolumes() async {
        let zones = groups.flatMap(\.members)
        let readings = await withTaskGroup(of: (id: String, volume: Int, muted: Bool)?.self) { group in
            for zone in zones {
                group.addTask {
                    async let volume = Self.getVolume(ip: zone.ip)
                    async let muted = Self.getMute(ip: zone.ip)
                    let v = (try? await volume) ?? 0
                    let m = (try? await muted) ?? false
                    return (zone.id, v, m)
                }
            }
            var out: [(id: String, volume: Int, muted: Bool)] = []
            for await reading in group { if let reading { out.append(reading) } }
            return out
        }
        for reading in readings {
            updateZone(reading.id) { $0.volume = reading.volume; $0.muted = reading.muted }
        }
    }

    private func refreshPlayState() async {
        let coordinators = groups.compactMap(\.coordinator)
        let states = await withTaskGroup(of: (id: String, playing: Bool)?.self) { group in
            for coordinator in coordinators {
                group.addTask { (coordinator.id, (try? await Self.isPlaying(ip: coordinator.ip)) ?? false) }
            }
            var out: [(id: String, playing: Bool)] = []
            for await state in group { if let state { out.append(state) } }
            return out
        }
        for state in states {
            if let index = groups.firstIndex(where: { $0.id == state.id }) {
                groups[index].isPlaying = state.playing
            }
        }
    }

    private func refreshNowPlaying() async {
        let coordinators = groups.compactMap(\.coordinator)
        let tracks = await withTaskGroup(of: (id: String, track: NowPlaying?)?.self) { group in
            for coordinator in coordinators {
                group.addTask { (coordinator.id, try? await Self.getNowPlaying(ip: coordinator.ip)) }
            }
            var out: [(id: String, track: NowPlaying?)] = []
            for await track in group { if let track { out.append(track) } }
            return out
        }
        for entry in tracks {
            if let index = groups.firstIndex(where: { $0.id == entry.id }) {
                groups[index].nowPlaying = entry.track
            }
        }
    }

    // MARK: - Live updates
    //
    // While the popover is open we poll the light, fast-changing state
    // (transport + track + position) so the UI stays live. We stop when it
    // closes to keep the network quiet.

    private var pollTask: Task<Void, Never>?

    func beginLiveUpdates() {
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshPlayState()
                await self?.refreshNowPlaying()
            }
        }
    }

    func endLiveUpdates() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Commands

    func setVolume(zoneId: String, to volume: Int) {
        let clamped = min(max(volume, 0), 100)
        updateZone(zoneId) { $0.volume = clamped }   // optimistic
        guard let ip = zone(zoneId)?.ip else { return }
        Task {
            _ = try? await SoapClient.send(
                ip: ip, service: SonosService.rendering, action: "SetVolume",
                arguments: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", "\(clamped)")]
            )
        }
    }

    /// Sets a whole group's volume at once via GroupRenderingControl on the
    /// coordinator (Sonos scales members proportionally), then re-reads members.
    func setGroupVolume(groupId: String, to volume: Int) {
        let clamped = min(max(volume, 0), 100)
        guard let coordinator = group(groupId)?.coordinator else { return }
        // Optimistically shift members toward the new level.
        let delta = clamped - (group(groupId)?.averageVolume ?? clamped)
        for member in group(groupId)?.members ?? [] {
            updateZone(member.id) { $0.volume = min(max($0.volume + delta, 0), 100) }
        }
        Task {
            _ = try? await SoapClient.send(
                ip: coordinator.ip, service: SonosService.groupRendering, action: "SetGroupVolume",
                arguments: [("InstanceID", "0"), ("DesiredVolume", "\(clamped)")]
            )
            await refreshVolumes()
        }
    }

    func toggleMute(zoneId: String) {
        guard let zone = zone(zoneId) else { return }
        let newValue = !zone.muted
        updateZone(zoneId) { $0.muted = newValue }
        Task {
            _ = try? await SoapClient.send(
                ip: zone.ip, service: SonosService.rendering, action: "SetMute",
                arguments: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredMute", newValue ? "1" : "0")]
            )
        }
    }

    func togglePlay(groupId: String) {
        guard let group = group(groupId), let coordinator = group.coordinator else { return }
        let action = group.isPlaying ? "Pause" : "Play"
        if let index = groups.firstIndex(where: { $0.id == groupId }) {
            groups[index].isPlaying.toggle()
        }
        Task {
            _ = try? await SoapClient.send(
                ip: coordinator.ip, service: SonosService.avTransport, action: action,
                arguments: action == "Play" ? [("InstanceID", "0"), ("Speed", "1")] : [("InstanceID", "0")]
            )
        }
    }

    func next(groupId: String) { transport(groupId: groupId, action: "Next") }
    func previous(groupId: String) { transport(groupId: groupId, action: "Previous") }

    /// Fires a simple `InstanceID`-only AVTransport action on the coordinator,
    /// then refreshes the track shortly after (the player needs a beat).
    private func transport(groupId: String, action: String) {
        guard let coordinator = group(groupId)?.coordinator else { return }
        Task {
            _ = try? await SoapClient.send(
                ip: coordinator.ip, service: SonosService.avTransport, action: action,
                arguments: [("InstanceID", "0")]
            )
            try? await Task.sleep(nanoseconds: 400_000_000)
            await refreshNowPlaying()
            await refreshPlayState()
        }
    }

    /// Seeks the group's current track to `seconds` from the start.
    func seek(groupId: String, to seconds: Int) {
        guard let coordinator = group(groupId)?.coordinator else { return }
        // Optimistically move the local position so the slider doesn't snap back.
        if let index = groups.firstIndex(where: { $0.id == groupId }) {
            groups[index].nowPlaying?.position = seconds
        }
        Task {
            _ = try? await SoapClient.send(
                ip: coordinator.ip, service: SonosService.avTransport, action: "Seek",
                arguments: [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", Self.hms(seconds))]
            )
        }
    }

    /// Adds `zoneId` to the group led by `coordinatorId`.
    func join(zoneId: String, toCoordinator coordinatorId: String) {
        guard let ip = zone(zoneId)?.ip, zoneId != coordinatorId else { return }
        Task {
            _ = try? await SoapClient.send(
                ip: ip, service: SonosService.avTransport, action: "SetAVTransportURI",
                arguments: [("InstanceID", "0"), ("CurrentURI", "x-rincon:\(coordinatorId)"), ("CurrentURIMetaData", "")]
            )
            await load()
        }
    }

    /// Removes `zoneId` from its group, making it a standalone player.
    func leave(zoneId: String) {
        guard let ip = zone(zoneId)?.ip else { return }
        Task {
            _ = try? await SoapClient.send(
                ip: ip, service: SonosService.avTransport, action: "BecomeCoordinatorOfStandaloneGroup",
                arguments: [("InstanceID", "0")]
            )
            await load()
        }
    }

    /// "Party mode": groups every room into one, led by the current first group.
    func groupAll() {
        let allZones = groups.flatMap(\.members)
        guard let lead = groups.first?.coordinator ?? allZones.first else { return }
        Task {
            for zone in allZones where zone.id != lead.id {
                _ = try? await SoapClient.send(
                    ip: zone.ip, service: SonosService.avTransport, action: "SetAVTransportURI",
                    arguments: [("InstanceID", "0"), ("CurrentURI", "x-rincon:\(lead.id)"), ("CurrentURIMetaData", "")]
                )
            }
            await load()
        }
    }

    /// Splits every room into its own standalone group.
    func ungroupAll() {
        let allZones = groups.flatMap(\.members)
        Task {
            for zone in allZones where !zone.isCoordinator {
                _ = try? await SoapClient.send(
                    ip: zone.ip, service: SonosService.avTransport, action: "BecomeCoordinatorOfStandaloneGroup",
                    arguments: [("InstanceID", "0")]
                )
            }
            await load()
        }
    }

    // MARK: - Readers (static, run off the main actor)

    private static func getVolume(ip: String) async throws -> Int {
        let response = try await SoapClient.send(
            ip: ip, service: SonosService.rendering, action: "GetVolume",
            arguments: [("InstanceID", "0"), ("Channel", "Master")]
        )
        return Int(SoapClient.value(of: "CurrentVolume", in: response) ?? "") ?? 0
    }

    private static func getMute(ip: String) async throws -> Bool {
        let response = try await SoapClient.send(
            ip: ip, service: SonosService.rendering, action: "GetMute",
            arguments: [("InstanceID", "0"), ("Channel", "Master")]
        )
        return SoapClient.value(of: "CurrentMute", in: response) == "1"
    }

    private static func isPlaying(ip: String) async throws -> Bool {
        let response = try await SoapClient.send(
            ip: ip, service: SonosService.avTransport, action: "GetTransportInfo",
            arguments: [("InstanceID", "0")]
        )
        return SoapClient.value(of: "CurrentTransportState", in: response) == "PLAYING"
    }

    /// Reads the coordinator's current track (title/artist/album/art + position).
    private static func getNowPlaying(ip: String) async throws -> NowPlaying? {
        let response = try await SoapClient.send(
            ip: ip, service: SonosService.avTransport, action: "GetPositionInfo",
            arguments: [("InstanceID", "0")]
        )
        let duration = seconds(from: SoapClient.value(of: "TrackDuration", in: response))
        let position = seconds(from: SoapClient.value(of: "RelTime", in: response))

        // TrackMetaData is DIDL-Lite XML, entity-escaped inside the response.
        guard let escaped = SoapClient.value(of: "TrackMetaData", in: response) else { return nil }
        let didl = SoapClient.unescape(escaped)

        func field(_ tag: String) -> String {
            SoapClient.value(of: tag, in: didl).map(SoapClient.unescape) ?? ""
        }
        let title = field("dc:title")
        // Radio/stream fallbacks when there's no discrete track title.
        let streamTitle = field("r:streamContent")
        let resolvedTitle = title.isEmpty ? streamTitle : title

        var artwork: URL?
        let art = field("upnp:albumArtURI")
        if !art.isEmpty {
            // Sonos gives either an absolute URL (e.g. Spotify CDN) or a path
            // relative to the coordinator (e.g. "/getaa?...").
            artwork = art.hasPrefix("http") ? URL(string: art) : URL(string: "http://\(ip):1400\(art)")
        }

        guard !resolvedTitle.isEmpty || !field("dc:creator").isEmpty else { return nil }
        return NowPlaying(
            title: resolvedTitle,
            artist: field("dc:creator"),
            album: field("upnp:album"),
            artworkURL: artwork,
            position: position,
            duration: duration
        )
    }

    /// Parses Sonos `H:MM:SS` (or `NOT_IMPLEMENTED`) into seconds.
    private static func seconds(from hms: String?) -> Int {
        guard let hms, hms.contains(":") else { return 0 }
        let parts = hms.split(separator: ":").compactMap { Int($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Formats seconds back into `H:MM:SS` for a Seek target.
    static func hms(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // MARK: - Local mutation helpers

    private func zone(_ id: String) -> SonosZone? {
        groups.flatMap(\.members).first { $0.id == id }
    }

    private func group(_ id: String) -> SonosGroup? {
        groups.first { $0.id == id }
    }

    private func updateZone(_ id: String, _ mutate: (inout SonosZone) -> Void) {
        for gi in groups.indices {
            if let zi = groups[gi].members.firstIndex(where: { $0.id == id }) {
                mutate(&groups[gi].members[zi])
                return
            }
        }
    }
}
