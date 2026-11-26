#!/bin/sh
# Installs or updates Netfuse in /Applications:
#   curl -fsSL https://raw.githubusercontent.com/masiur/netfuse/main/install.sh | sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo "Netfuse runs on macOS only." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "Netfuse needs an Apple Silicon Mac for now." >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading Netfuse..."
curl -fL --progress-bar -o "$tmp/Netfuse.zip" https://github.com/masiur/netfuse/releases/latest/download/Netfuse.zip
ditto -x -k "$tmp/Netfuse.zip" "$tmp"
# The app is not notarized yet; a copy downloaded with curl carries no quarantine flag, but clear it
# in case something added one.
xattr -dr com.apple.quarantine "$tmp/Netfuse.app" 2>/dev/null || true

# Quit a running copy so it can be replaced. The engine keeps running; the new app offers its update.
osascript -e 'quit app id "app.netfuse.Netfuse"' 2>/dev/null || true
dest=/Applications/Netfuse.app
sudo=
[ -w /Applications ] && { [ ! -e "$dest" ] || [ -w "$dest" ]; } || sudo=sudo
$sudo rm -rf "$dest"
$sudo mv "$tmp/Netfuse.app" "$dest"
echo "Installed $dest"
open "$dest"
