# SonosControl — Lessons Learned

A field guide for the next agent (or human) working on this project. This is not
the how-to (see [README.md](README.md)); it's the *why* — the wrong turns we took,
the symptoms that misled us, and what actually fixed them. Read it before you
start debugging, so you don't re-run the dead ends.

---

## TL;DR — the three things that actually mattered

1. **Sonos discovery failed because the Wi-Fi router filters SSDP multicast**, not
   because of a permission or a bug. Speakers were reachable the whole time via
   plain unicast on port `1400`. Fix: a **subnet scan** fallback + cached IPs +
   manual "add by IP". Never assume "no reply to M-SEARCH" means "no speakers."
2. **The macOS Local Network prompt was a red herring.** The app was already
   reaching the speakers with its own identity. Verify actual network behavior
   before blaming permissions.
3. **This environment has sharp edges** — no `timeout`, `log --predicate` gets
   mangled by the shell, `swiftc`/`codesign` need `dangerouslyDisableSandbox`, and
   SwiftPM's manifest evaluator is broken. Compile with `swiftc` directly.

---

## 1. Discovery: SSDP multicast is unreliable; unicast is the truth

**Symptom:** The app showed "No Sonos found on this network," yet Spotify was
happily playing to the speakers. The user (reasonably) concluded the speakers
weren't visible.

**What we assumed first (wrong):** That it was a Local Network permission problem
blocking the multicast.

**What was actually happening:** Sonos discovery uses SSDP — an `M-SEARCH`
multicast to `239.255.255.250:1900`. **Consumer Wi-Fi routers very commonly drop
or filter multicast/IGMP**, so the M-SEARCH goes out and nothing comes back —
even though every speaker is fully reachable by unicast.

**How we proved it:** A dumb unicast sweep of the `/24` found all three speakers
instantly:

```bash
for i in $(seq 1 254); do
  ( curl -s -m 1 -o /tmp/s.xml "http://192.168.20.$i:1400/xml/device_description.xml" \
      && grep -o '<roomName>[^<]*</roomName>' /tmp/s.xml ) &
  (( i % 64 == 0 )) && wait
done; wait
```

`http://<ip>:1400/xml/device_description.xml` returns the device description
(contains `Sonos` / `ZonePlayer`); a single reachable player's
`GetZoneGroupState` then returns the **whole system's** topology.

**The fix (in `SonosDiscovery.swift` + `SonosController.load()`):** a three-tier
discovery ladder, cheapest first:

1. **Cached IPs** (persisted in `UserDefaults` `knownSonosIPs`) — instant on later launches.
2. **SSDP** — fast when it works.
3. **Subnet scan** — probe `:1400` on every host of each local `/24`
   (`getifaddrs` → interface prefixes), 64 at a time. Reliable when multicast is
   filtered.
4. **Manual "add by IP"** in the UI — the guaranteed escape hatch for weird
   networks / VLANs / client isolation.

**Takeaway:** For any LAN device discovery (Sonos, Chromecast, HomeKit bridges,
printers), treat multicast discovery as best-effort and **always** have a unicast
scan + manual entry fallback. Cache what you find.

---

## 2. macOS Local Network permission — verify, don't assume

**Symptom:** "I did not get the local network message." We expected macOS to
prompt *"SonosControl would like to find and connect to devices on your local
network"* and it never did, so we suspected the app was silently blocked.

**Reality:** The app was already connecting. The prompt didn't appear because it
wasn't needed / was already resolved for this app identity.

**How to actually check what the app can do** (this is the useful part — the
naive checks all lied):

- **Do NOT run the binary from Terminal to test network permission.** Running
  `./App.app/Contents/MacOS/App` from a shell attributes network access to
  *Terminal's* Local Network grant, not the app's. It'll connect even if the app
  itself is blocked — a false pass.
- **DO launch via `open` and capture the app's own stderr:**

  ```bash
  open -n --stderr /tmp/app_err.txt /path/to/App.app
  sleep 6
  grep "MyTag:" /tmp/app_err.txt
  ```

  This runs the app with its real TCC identity *and* gives you its `NSLog`
  output. This is how we confirmed `firstReachable -> 192.168.20.4` succeeded in
  ~48 ms under the app's own identity — proving permission was not the blocker.

**Facts about the Local Network prompt worth knowing:**

- It fires (at most) **once per app identity**, on first local-network access.
  If a prior build already resolved it (allowed *or* denied), you won't see it
  again — macOS caches the decision keyed on the app's designated requirement.
- Because we sign with a **stable identity** (see §3), the grant/denial persists
  across rebuilds — good when allowed, but it also means a stale *denial* won't
  re-prompt. If you ever need a clean prompt, the decision lives in the Local
  Network privacy DB, not the classic `TCC.db`; toggle it in **System Settings →
  Privacy & Security → Local Network**.
- `NSLocalNetworkUsageDescription` must be in `Info.plist` (it is) or the app
  can be denied outright.
- **You cannot click the prompt for the user.** It's a system modal. Don't
  design a flow that depends on an agent dismissing it.

**Takeaway:** When a networked app "doesn't work," instrument it and observe
before theorizing about permissions. The permission was the *last* thing wrong
here, not the first.

---

## 3. Menu-bar agent UX: icon visibility and the "popup" trap

**Symptom 1:** "I don't see anything." The app was running (verified via `pgrep`,
no crash reports) but its `NSStatusItem` icon was **invisible** — hidden in the
MacBook notch / an overcrowded menu bar.

**What we tried:**
- Adding a `" Sonos"` text label next to the icon — helps you find it, but the
  overflow can still hide it behind the notch.
- Switching from `NSPopover` to a **centered floating `NSPanel`** shown on launch.
  This guaranteed visibility... but the user hated it: *"do not open it in a
  popup."* A window that appears uninvited in the middle of the screen is not
  what people expect from a menu-bar app.

**Where we landed (correct):** Back to an **`NSPopover` anchored to the status
item** (`behavior = .transient`, closes on click-away), that opens **on click**,
**not** on launch. Plus a **global hotkey (⌘⌥S)** via Carbon as an escape hatch
if the icon is hard to find. Discovery is warmed in the background at launch so
the list is ready on first open, but nothing is shown uninvited.

**Takeaways:**
- Menu-bar (`LSUIElement` / `.accessory`) apps **can be invisible** on notched
  Macs. Don't assume "running" == "the user can see it."
- The right visibility escape hatch is a **global hotkey**, not a floating window.
  Carbon `RegisterEventHotKey` needs no permissions (unlike a `CGEventTap`).
- Match the platform idiom: menu-bar app → popover under the icon, opened on
  demand. Don't shove a window at the user.

---

## 4. Build & tooling gotchas in this environment

These cost real time; hard-won:

- **SwiftPM's manifest evaluator is broken here.** `swift build` fails. We compile
  directly: `swiftc -O Sources/SonosControl/*.swift ...` (see `build.sh`). Don't
  waste time on a `Package.swift`.
- **`swiftc`, `codesign`, and the signing setup need `dangerouslyDisableSandbox:
  true`** on the Bash tool, or they fail under the sandbox.
- **`timeout` does not exist on macOS** (no GNU coreutils). `timeout 8 ./app`
  silently produces *nothing* — the command just isn't found, and if it's on the
  left of a pipe you get empty output and a confusing "success." Use
  `cmd & PID=$!; sleep N; kill $PID` instead.
- **`log show` / `log stream` with `--predicate '...'` gets mangled** by this
  harness's `zsh` eval ("too many arguments"). Don't rely on unified-log
  predicates for debugging here. Instead, **have the app `NSLog` and capture its
  stderr via `open --stderr <file>`** (see §2) — far more reliable.
- **Crash check:** `ls ~/Library/Logs/DiagnosticReports/<App>*` — absence means no
  crash, so if the user "sees nothing" it's a UI/visibility issue, not a crash.

---

## 5. Stable self-signed code signing (so grants stick across rebuilds)

**Problem:** An **ad-hoc** signature (`codesign -s -`) gets a fresh `cdhash` every
build, so macOS treats each rebuild as a *different app* and drops every TCC grant
(Local Network here; Accessibility/Screen Recording in the sibling WindowList
app). You'd have to re-grant permissions on every single build.

**Fix:** Sign with a **stable self-signed identity** (`scripts/setup-signing.sh`):
a self-signed `codeSigning`-EKU cert in a dedicated keychain, used as the signing
identity every build. TCC keys on the designated requirement (bundle id + signing
cert), so the grant **persists across rebuilds**. You grant once.

**The sharp edge we hit (documented so you don't repeat it):**
- The idempotency check must use `security find-identity "$KEYCHAIN"` **without
  `-v`**. `-v` only lists *trust-valid* identities, and a self-signed cert is
  **not** trust-valid — so a `-v`-based check never matches and re-imports a
  duplicate identity every run. Duplicates make `codesign --sign "<name>"`
  ambiguous, and it silently falls back to ad-hoc → grants drop again.
- `security find-identity -v` reporting **"0 valid identities" /
  `CSSMERR_TP_NOT_TRUSTED`** for our cert is **EXPECTED and harmless** — it does
  **not** block signing. Don't "fix" it.
- `security set-key-partition-list` on the key avoids the interactive codesign
  keychain-access prompt.

This pattern is shared with the sibling **WindowList** app — same script shape,
different identity name.

---

## 6. Sonos protocol notes (so you don't re-learn the API)

- **No cloud/account needed.** Everything is local UPnP/SOAP on port **1400**.
- **One player tells you everything.** `ZoneGroupTopology#GetZoneGroupState` on
  *any* reachable player returns the entire system: every room, its IP/UUID, and
  the current grouping.
- **`ZoneGroupState` is double-escaped XML** — the inner topology is HTML-escaped
  *inside* the SOAP response. Parse in two passes (see `Topology.swift`); when
  probing by hand, `html.unescape` **twice**.
- **Skip `Invisible="1"` members.** Bonded devices — subwoofers and surround
  satellites (we have a **"Sub 4"**) — appear as group members but are not their
  own controllable rooms. Filtering them out is why the UI shows "Dining Room"
  and not a phantom "Sub 4" row.
- **Coordinator vs member.** Each `ZoneGroup` has a `Coordinator` UUID; transport
  (play/pause) and group volume go to the coordinator; per-room volume/mute go to
  each member.
- **Grouping:**
  - *Join*: `AVTransport#SetAVTransportURI` with `CurrentURI = "x-rincon:<coordinatorUUID>"`.
  - *Leave*: `AVTransport#BecomeCoordinatorOfStandaloneGroup`.
  - *Party* = join everyone to one coordinator; *Split* = every room becomes its
    own coordinator.
- **Volume:** per-room via `RenderingControl#SetVolume/GetVolume`; whole-group via
  `GroupRenderingControl#SetGroupVolume` on the coordinator (Sonos scales members
  proportionally). Send volume **on slider release**, not while dragging, or you
  flood the player with SOAP calls.
- **Now-playing / Spotify controls (no Spotify API needed).** The current track
  is exposed by Sonos itself, whatever the source:
  - `AVTransport#GetPositionInfo` on the coordinator returns `TrackDuration`,
    `RelTime` (position), and `TrackMetaData`.
  - **`TrackMetaData` is DIDL-Lite XML, entity-escaped *inside* the SOAP
    response** — unescape once, then read `dc:title`, `dc:creator` (artist),
    `upnp:album`, `upnp:albumArtURI`. Fields may themselves contain entities, so
    unescape each again. (This is the *same* double-escaping trap as
    `ZoneGroupState`.)
  - **Album art is sometimes absolute, sometimes relative.** Spotify gives a full
    `https://i.scdn.co/...` URL (load directly); other sources give a path like
    `/getaa?...` that must be prefixed with `http://<coordinatorIP>:1400`.
  - Times are `H:MM:SS` (or `NOT_IMPLEMENTED`). Skip: `AVTransport#Next` /
    `#Previous`; scrub: `#Seek` with `Unit=REL_TIME`, `Target=H:MM:SS`. These
    work on the Spotify queue (`TrackURI` shows `x-sonos-vli:` / `x-sonos-spotify:`).
  - There is **no local "search for a song"** — queueing *new* Spotify tracks
    needs the Spotify Web API + OAuth. Transport over the *existing* queue is all
    local.
  - We **poll** `GetPositionInfo` every ~2 s while the popover is open (started
    from `NSPopoverDelegate.popoverDidShow`, stopped on `popoverDidClose`) so the
    track/progress stay live without hammering the network when closed. Sonos
    also supports GENA event subscriptions (push) if you want to avoid polling.

---

## 7. Swift 6 concurrency reminders (this codebase is strict-concurrency)

- Entry point boots AppKit inside `MainActor.assumeIsolated { ... app.run() }`
  (`main.swift`); the `AppDelegate` is `@MainActor`.
- The Carbon hotkey C callback can't capture context, so live `HotKey` instances
  are looked up through a **static registry keyed by hotkey id**, and the callback
  hops to the main actor via `DispatchQueue.main.async { MainActor.assumeIsolated { ... } }`.
- `deinit` is nonisolated — hop to the main actor with a `Task { @MainActor in ... }`
  to touch main-actor state (registry cleanup).
- Network reads (`getVolume`/`getMute`/`isPlaying`) are `static` and run off the
  main actor; results are applied back on the main actor. SSDP is blocking BSD
  sockets — run it via `Task.detached`.

---

## Checklist for the next agent

- [ ] Speakers "not found"? Run the unicast `:1400` sweep (§1) before touching
      discovery or permission code — confirm they're reachable at all.
- [ ] App "invisible"? Check `pgrep` + crash reports; it's almost certainly the
      menu-bar icon hidden by the notch, not a crash. Use ⌘⌥S.
- [ ] Testing network/permission behavior? Launch via `open --stderr <file>`,
      never the raw binary from Terminal (§2).
- [ ] Don't use `timeout`; don't rely on `log --predicate` here (§4).
- [ ] After editing signing, verify a **single** identity and a real
      `codesign --sign "SonosControl Self-Signed"` (not an ad-hoc fallback) (§5).
- [ ] Don't add an uninvited floating window; keep the popover-under-the-icon
      idiom (§3).
