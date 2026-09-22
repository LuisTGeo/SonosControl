import SwiftUI
import ServiceManagement

/// The control panel: one section per Sonos group, with play/pause, a group
/// volume slider, and per-room volume + mute + grouping controls.
struct ContentView: View {
    @EnvironmentObject private var controller: SonosController

    /// Live slider values while dragging, so we only send a command on release
    /// (avoids flooding the player with SOAP calls).
    @State private var draft: [String: Double] = [:]

    /// Manual IP entry used as a fallback when discovery is blocked.
    @State private var manualIP: String = ""
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .alert("Couldn't update login setting", isPresented: Binding(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )) {
            Button("OK", role: .cancel) { loginItemError = nil }
        } message: {
            Text(loginItemError ?? "Please try again in System Settings.")
        }
        // Must match the popover's contentSize exactly, or the content renders
        // offset inside the popover (a gap appears above/below).
        .frame(width: 360, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.2.fill")
            Text("Sonos").font(.headline)
            if controller.isLoading {
                ProgressView().controlSize(.small).padding(.leading, 2)
            }
            Spacer()
            Button(action: { controller.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Rescan for speakers")
        }
        .padding(10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if controller.groups.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                Text(controller.status ?? (controller.isLoading ? "Searching…" : "No speakers"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if controller.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Rescan") { controller.refresh() }

                    Text("If the speaker isn't found, check System Settings → Privacy & Security → Local Network and enable SonosControl — or add it by IP:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                    HStack {
                        TextField("192.168.1.20", text: $manualIP)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { submitManualIP() }
                        Button("Add") { submitManualIP() }
                            .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 24)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
        } else {
            List {
                if let status = controller.status {
                    Label(status, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(controller.groups) { group in
                    Section {
                        nowPlayingRow(group)
                        if group.members.count > 1 {
                            groupVolumeRow(group)
                        }
                        ForEach(group.members) { zone in
                            zoneRow(zone, in: group)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func groupHeader(_ group: SonosGroup) -> some View {
        HStack(spacing: 8) {
            Button(action: { controller.togglePlay(groupId: group.id) }) {
                Image(systemName: group.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help(group.isPlaying ? "Pause" : "Play")

            Text(group.name).fontWeight(.semibold)
            Spacer()
            if group.members.count > 1 {
                Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Now playing

    @ViewBuilder
    private func nowPlayingRow(_ group: SonosGroup) -> some View {
        let np = group.nowPlaying
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                artwork(np.flatMap { $0.hasTrack ? $0.artworkURL : nil })
                VStack(alignment: .leading, spacing: 2) {
                    if let np, np.hasTrack {
                        Text(np.title).font(.callout).fontWeight(.semibold).lineLimit(1)
                        if !np.artist.isEmpty {
                            Text(np.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !np.album.isEmpty {
                            Text(np.album).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Text("Nothing playing").font(.callout).fontWeight(.semibold).lineLimit(1)
                        Text("Choose something in the Sonos app")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            transportRow(group, np)
        }
        .padding(.vertical, 4)
    }

    private func artwork(_ url: URL?) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func transportRow(_ group: SonosGroup, _ np: NowPlaying?) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 28) {
                Button(action: { controller.previous(groupId: group.id) }) {
                    Image(systemName: "backward.fill")
                }
                .help("Previous")
                Button(action: { controller.togglePlay(groupId: group.id) }) {
                    Image(systemName: group.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                .help(group.isPlaying ? "Pause" : "Play")
                Button(action: { controller.next(groupId: group.id) }) {
                    Image(systemName: "forward.fill")
                }
                .help("Next")
            }
            .buttonStyle(.plain)

            if let np, np.duration > 0 {
                HStack(spacing: 6) {
                    Text(timeLabel(np.position)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    Slider(value: seekBinding(group: group, np: np), in: 0...Double(np.duration)) { editing in
                        if !editing { commitSeek(group: group) }
                    }
                    Text(timeLabel(np.duration)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func groupVolumeRow(_ group: SonosGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary).frame(width: 18)
            Slider(
                value: binding(id: "group-\(group.id)", current: group.averageVolume),
                in: 0...100, step: 1
            ) { editing in
                if !editing { commit(id: "group-\(group.id)") { controller.setGroupVolume(groupId: group.id, to: $0) } }
            }
            .accessibilityLabel("\(group.name) group volume")
            .accessibilityValue("\(group.averageVolume) percent")
            Text("Group").font(.caption2).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }

    private func zoneRow(_ zone: SonosZone, in group: SonosGroup) -> some View {
        HStack(spacing: 8) {
            Button(action: { controller.toggleMute(zoneId: zone.id) }) {
                Image(systemName: zone.muted ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(zone.muted ? .secondary : .primary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(zone.muted ? "Unmute" : "Mute")
            .accessibilityLabel(zone.muted ? "Unmute \(zone.name)" : "Mute \(zone.name)")

            VStack(alignment: .leading, spacing: 2) {
                Text(zone.name).font(.callout)
                Slider(
                    value: binding(id: zone.id, current: zone.volume),
                    in: 0...100, step: 1
                ) { editing in
                    if !editing { commit(id: zone.id) { controller.setVolume(zoneId: zone.id, to: $0) } }
                }
                .accessibilityLabel("\(zone.name) volume")
                .accessibilityValue("\(zone.volume) percent")
            }

            groupMenu(for: zone)
        }
    }

    private func groupMenu(for zone: SonosZone) -> some View {
        Menu {
            let others = controller.groups.filter { $0.id != zone.coordinatorId }
            if !others.isEmpty {
                Section("Join group") {
                    ForEach(others) { target in
                        Button(target.name) { controller.join(zoneId: zone.id, toCoordinator: target.id) }
                    }
                }
            }
            // Offer "Ungroup" when this zone shares a group with others.
            if let group = controller.groups.first(where: { $0.id == zone.coordinatorId }), group.members.count > 1 {
                Button("Ungroup \(zone.name)") { controller.leave(zoneId: zone.id) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Grouping")
        .accessibilityLabel("Group options for \(zone.name)")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: { controller.groupAll() }) {
                Label("Party", systemImage: "person.3.fill")
            }
            .disabled(controller.groups.isEmpty || controller.isLoading)
            .help("Group every room together")

            Button(action: { controller.ungroupAll() }) {
                Label("Split", systemImage: "rectangle.split.3x1")
            }
            .disabled(controller.groups.isEmpty || controller.isLoading)
            .help("Ungroup all rooms")

            Menu {
                Toggle("Start at Login", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { setLaunchAtLogin($0) }
                ))
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Settings")

            Spacer()

            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit SonosControl")
        }
        .font(.caption)
        .padding(8)
    }

    // MARK: - Slider helpers

    /// A binding that reads the draft value while dragging, otherwise the live
    /// value from the controller.
    private func binding(id: String, current: Int) -> Binding<Double> {
        Binding(
            get: { draft[id] ?? Double(current) },
            set: { draft[id] = $0 }
        )
    }

    private func commit(id: String, _ apply: (Int) -> Void) {
        if let value = draft[id] { apply(Int(value.rounded())) }
        draft[id] = nil
    }

    private func seekBinding(group: SonosGroup, np: NowPlaying) -> Binding<Double> {
        Binding(
            get: { draft["seek-\(group.id)"] ?? Double(np.position) },
            set: { draft["seek-\(group.id)"] = $0 }
        )
    }

    private func commitSeek(group: SonosGroup) {
        let key = "seek-\(group.id)"
        if let value = draft[key] { controller.seek(groupId: group.id, to: Int(value)) }
        draft[key] = nil
    }

    private func timeLabel(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func submitManualIP() {
        let ip = manualIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        controller.addManualIP(ip)
        manualIP = ""
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = enabled
        } catch {
            loginItemError = error.localizedDescription
        }
    }
}
