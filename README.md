# Netfuse

Use all your Mac's internet connections at once: Wi-Fi, Ethernet, an iPhone or Android phone over
USB, and USB network adapters. Connections are shared out by speed, and you choose per app which
connection it uses.

## Install

Apple Silicon, macOS 14 or later:

```sh
curl -fsSL https://raw.githubusercontent.com/masiur/netfuse/main/install.sh | sh
```

The same command updates Netfuse. The first time you switch it on, it asks for your password to
install its routing engine; later engine updates ask once more, from the menu.

## Features

- **Combine connections.** Each new connection goes out through one of your links, picked by
  speed: a link twice as fast carries about twice as many. Speed comes from a short download test
  when a link appears (kept for a day per network), then from the traffic the link actually
  carries. A failing link is skipped for 15 seconds and connections retry on the others.
- **Per-app rules.** Each app can use all connections, only one, or one first with fallback to the
  rest. Helper processes follow their app's rule.
- **Android USB tethering, built in.** Phones that tether over RNDIS (most Samsung, Honor,
  Xiaomi, Oppo and similar) work with no driver, kernel extension or security change, and appear by
  their model name. Phones macOS already supports, such as Pixel 6 and later, work as normal
  adapters.
- **iPhone.** USB Personal Hotspot works alongside your other links. If macOS keeps it off
  ("Disable unless needed"), the menu explains how to turn that off and opens Network settings.
- **Menu bar.** Live speed per connection, which link each app is on, and an on/off switch.
- **Details window.** A sidebar of connections and an overview with combined traffic and every
  app's connections. Each connection shows its last 10 minutes of traffic, public IP, provider,
  local IP, router, MAC address, link speed, estimated speed and share of new connections.

## Good to know

- IPv6 is switched off while Netfuse is on, so every connection follows its app's rule.
- Each download uses one link; combining shows when several things download at once.
- Android phones work only while Netfuse is on, because Netfuse is their driver. If one stops
  answering, turn USB tethering off and on. One Android USB phone at a time.
- Traffic from virtual machines and Internet Sharing has no app behind it and is listed as
  "Virtual machines & system".
- The app isn't notarized yet.

## How it works

The menu-bar app (`app/`, SwiftUI) writes per-app rules; the engine (`engine/`, Rust) runs as a
root LaunchDaemon while Netfuse is on. It captures IPv4 traffic with a utun device, ends each
connection in a userspace TCP/IP stack, finds the app that opened it, and dials it again from the
chosen adapter with a socket bound to that adapter. Android phones are driven over USB (RNDIS) and
given a feth interface. See [PLAN.md](PLAN.md) for the design.

## Develop

- App: `app/scripts/bundle.sh --open` builds and opens `app/build/Netfuse.app`, with the engine inside.
- Engine: `cargo test` in `engine/`. `netfuse-engine list` shows the adapters it would use, and
  `netfuse-engine phone` checks an Android phone's USB tethering without root.
- Release: `app/scripts/release.sh X.Y.Z` on a clean tree.
