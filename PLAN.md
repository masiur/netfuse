# Nethance: plan

Goal: a macOS menu-bar app that uses Wi-Fi, Ethernet, the phone hotspot (USB / Bluetooth) and
USB adapters **at the same time**, and lets you choose per app: *this adapter*, *combine all*, or
*this adapter, then fall back to that one*.

## What we start from

**net-merge** (MIT, Go, about 7.6k LOC) — checked:
- `go build ./cmd/net-merge` builds on this Mac (Go 1.27, 17 s). `net-merge list` sees `en0` Wi-Fi and skips
  `en1–en6` because they have no gateway yet.
- How it works: it creates a `utun` and adds two `/1` routes. A gVisor userland stack (tun2socks) ends every
  TCP/UDP flow. The scheduler (`internal/engine/sched.go`, `AcquireFor`) picks an adapter, then re-dials the
  server with `IP_BOUND_IF` on that adapter.
- What it can't do: one connection always uses one link (no server in the middle). It doesn't know which
  **app** a flow came from, so it has no per-app rules.
- Adapter filter `^(en|feth)\d+$`. It already covers Wi-Fi, Ethernet/USB NICs, iPhone USB and Bluetooth PAN
  (both are `enN`), and Android via TetherKit (`fethN`).
- Control: `status.json` plus marker files in `ctl/`. Root comes from a sudoers rule (`net-merge install`).

**RoutEngine** is the commercial version of net-merge: adapter per app, fallback, speed and data caps per
app. It is closed source, so we use it only as a feature reference and copy none of its code.

**Other tools**
| Tool | Approach | Useful to us |
|---|---|---|
| Speedify / Connectify | Commercial, bonding through their own servers | Shows that single-connection speed-up needs a server |
| OpenMPTCProuter / BondingShouldBeFree | MPTCP to a VPS, router-side (OpenWrt) | Optional later "true bonding" mode |
| [Shunt](https://github.com/craraque/shunt) | macOS Network Extension, per-app → SOCKS5 | Reference for the per-app NE plumbing |
| Portmaster split tunnel | Per-app interface binding | Same idea; on macOS a third party can't do it without an NE |

## Hard limits (physics and macOS, not code)
1. **One Wi-Fi radio joins one network.** Home Wi-Fi *and* the phone hotspot over Wi-Fi at once isn't
   possible. Put the phone on **USB** (iPhone: built in; Android: TetherKit) or **Bluetooth PAN**, or add a
   USB Wi-Fi dongle (drivers on Apple Silicon are poor).
2. Combining only adds speed when the links have **separate uplinks** (home ISP + mobile). Wi-Fi and Ethernet
   on the same router don't.
3. One TCP connection stays on one link. Real single-flow bonding needs a VPS (MPTCP). Optional phase 5.
4. Bluetooth PAN tops out around 1–3 Mbit/s. It's fine for failover, not for speed.

## Two ways to get "which app uses which internet"

**A. Keep net-merge's TUN and look up which process owns a flow (fast path, no Apple account)**
- When a SYN or first UDP packet arrives, take its source port and find the socket owner with
  libproc (`proc_listpids` → `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`), then PID → executable path →
  bundle ID.
- Rule lookup: `bundleID → {adapter | balance | [adapterA, adapterB…] fallback}`. Feed it into
  `AcquireFor` as an allow-list. It's a small change because `skip` already exists.
- Cost: a lookup per new flow (cache per port), and it can be fooled by helper processes, e.g. Chrome
  helpers. Map those through the parent app bundle.

**B. Rebuild on Apple's `NETransparentProxyProvider` (the "proper" path)**
- The system hands every flow to us with `sourceAppSigningIdentifier` and audit token. We then
  dial with `NWConnection(requiredInterface:)`. App identity is exact, no TUN, no route hacks, and it
  works next to VPNs better.
- Cost: Swift rewrite of the data plane, **Apple Developer ID ($99/yr)**, system-extension
  entitlement, notarization, and the user approves it in System Settings.

**Recommendation:** ship A first (weeks, reuses net-merge), and move to B only if app identity from A
proves unreliable or you want to distribute it widely.

## Decisions (26 Nov 2026)
- **Path A** (no Apple Developer ID yet). Path B stays an option once there is one.
- **Swift app + Rust engine, no Go.** `app/`: SwiftUI menu-bar app. `engine/`: Rust root daemon (TUN,
  userland TCP/IP stack, per-app routing). The Go net-merge fork was only a prototype that proved the rule
  model and app lookup; it is not part of this repo.
- **Design:** Astryx (astryx.atmeta.com) tokens, translated by hand in `app/Sources/Nethance/Theme.swift`.
- **Android USB:** the test phone only offers RNDIS, which macOS cannot use without TetherKit.

## Contract between app and engine
- Rules: `~/Library/Application Support/Nethance/rules.json`, `{"version":1,"rules":{"<app>":"<route>"}}`.
  `<app>` is the outermost `.app` bundle's name (or the executable's name for CLI tools).
  `<route>` lists adapter tiers separated by `>` and tried in order; adapters joined by `+` are combined.
  An adapter is a BSD name (`en4`) or a service name (`Wi-Fi`); `*` means every adapter and `auto` means
  no rule. Example: `en4 > *`.
- Status: `/var/run/nethance/status.json`, rewritten every second while the engine runs.

## Phases
0. **Validate hardware.** Bring up each link (Wi-Fi, Ethernet, iPhone USB, Bluetooth PAN, Android via
   TetherKit) and confirm each one shows up as a usable connection.
1. **Menu-bar app** (done, first version). Shows connections with live speed and running apps, with a
   per-app picker (all / only X / X first). It saves `rules.json`.
2. **Rust engine.** utun + `/1` routes, a userland TCP/IP stack, sockets pinned per adapter
   (`IP_BOUND_IF`), probes and weighted balancing, app lookup through libproc, and `rules.json` with
   hot reload. Install as a root LaunchDaemon (`SMAppService.daemon` from the app).
3. **Router extras.** Per-app speed and data caps, a "metered link" flag, and showing which app is on
   which link.
4. **Packaging.** Signed and notarized `.app` + DMG, auto-start, and an uninstall that removes the routes.
5. *(Optional)* Path B system extension, and/or MPTCP to a VPS for single-flow bonding.
