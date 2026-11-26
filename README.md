# Netfuse

Use Wi-Fi, Ethernet, phone tethers and USB adapters at the same time on macOS, and choose which app
uses which connection.

Install or update (Apple Silicon, macOS 14+):

```sh
curl -fsSL https://raw.githubusercontent.com/masiur/netfuse/main/install.sh | sh
```

Releases: `app/scripts/release.sh X.Y.Z` on a clean tree.

- `app/`: SwiftUI menu-bar app. Build it with `app/scripts/bundle.sh --open`.
- `engine/`: Rust routing engine (in progress).

See [PLAN.md](PLAN.md) for the design and roadmap.
