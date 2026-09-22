# SonosControl

A minimalist macOS **menu-bar Sonos controller**. Click the speaker icon to see
your rooms grouped as they're currently playing, adjust volume, mute, play/pause,
and group/ungroup speakers — all over the local network, no Sonos account or
cloud required.

Built as a lightweight companion to [WindowList](../WindowList): same approach —
a menu-bar agent compiled with `swiftc` and signed with a stable self-signed
identity so its permission grant sticks across rebuilds.

## How it works

Sonos players expose a local UPnP/SOAP API on port **1400**. SonosControl:

1. **Discovers** a player three ways, in order: cached IPs → SSDP (an
   `M-SEARCH` multicast for `ZonePlayer`) → a direct **subnet scan** that probes
   `:1400` on every host of the local /24. The scan is the reliable path when
   Wi-Fi routers filter multicast (common), and you can also **add a speaker by
   IP** by hand if all else fails.
2. Reads the whole system's **zone-group topology** from that one player
   (`GetZoneGroupState`) — every room, its IP, and the current grouping.
3. Reads/writes **volume & mute** (`RenderingControl` / `GroupRenderingControl`),
   **transport** (`AVTransport` Play/Pause/Next/Previous/Seek), and **grouping**
   (`SetAVTransportURI x-rincon:…` to join, `BecomeCoordinatorOfStandaloneGroup`
   to leave).
4. Reads the **now-playing** track (`AVTransport GetPositionInfo`) — title,
   artist, album, album art, and position — for whatever the group is playing
   (Spotify, radio, etc.; Sonos reports the same metadata regardless of source).
   While the panel is open it polls this every couple of seconds so the track
   and progress stay live.

Discovered IPs are cached so later launches skip the multicast round-trip.

## Build & run

Requires macOS 14+ and the Xcode command-line tools.

```bash
./build.sh          # compiles + signs build/SonosControl.app
open build/SonosControl.app
```

A speaker icon appears in the menu bar; click it to open the anchored panel,
matching the companion WindowList app. The panel closes when you click away and
can also be toggled from anywhere with **⌘⌥S**, so you can reach it even if the
menu-bar icon is hidden behind the notch.

## Permissions

- **Local Network** — required to find and talk to the speakers. macOS prompts
  on the first scan; allow it. (You can toggle it later under System Settings →
  Privacy & Security → Local Network.)

The app is signed with a **stable self-signed identity** (`scripts/setup-signing.sh`),
so unlike an ad-hoc build the Local Network grant persists across rebuilds — you
grant once.

## Using the panel

- **Now playing** — per group: **album art**, **title / artist / album**, a
  transport row (**⏮ previous · play/pause · next ⏭**), and a **seek bar** with
  elapsed/remaining time. This is your Spotify remote — skip, pause, and scrub
  without leaving the menu bar.
- **Per group** — a header with **play/pause**, the group name ("Living Room +2"
  when grouped), and a **Group** volume slider for multi-room groups.
- **Per room** — a **mute** toggle, a **volume** slider (sends on release, so it
  won't flood the speaker while dragging), and a **⋯ menu** to *Join* another
  group or *Ungroup* this room.
- **Footer** — **Party** groups every room into one; **Split** ungroups them all;
  **⟳** (top-right) rescans; the **⚙︎** menu can enable **Start at Login**; the
  power button quits.

## Architecture

| File | Responsibility |
|------|----------------|
| `main.swift` | Entry point; boots the AppKit app as a menu-bar agent. |
| `AppDelegate.swift` | Status item + floating panel + global hotkey; kicks off discovery. |
| `HotKey.swift` | Carbon global hotkey (⌘⌥S) to toggle the panel. |
| `SonosDiscovery.swift` | SSDP `M-SEARCH` + subnet-scan fallback → player IPs. |
| `SonosModels.swift` | `SonosZone` / `SonosGroup` models + SOAP service coordinates. |
| `SoapClient.swift` | Builds/sends UPnP SOAP requests; pulls values from responses. |
| `Topology.swift` | Parses `GetZoneGroupState` into the current groups. |
| `SonosController.swift` | Discovery, topology, volume/mute/transport, now-playing, grouping, live polling. |
| `ContentView.swift` | The grouped control panel UI (now-playing strip + volume/grouping). |

## Ideas for later

- Live updates via the players' UPnP event subscriptions (GENA) instead of polling.
- Favorites / playlist launching.
- A search box to queue Spotify tracks directly (needs the Spotify Web API + auth).
