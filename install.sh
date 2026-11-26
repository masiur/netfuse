#!/bin/sh
# Installs or updates Nethance in /Applications:
#   curl -fsSL https://raw.githubusercontent.com/masiur/nethance/main/install.sh | sh
set -eu
[ "$(uname -s)" = Darwin ] || { echo "Nethance runs on macOS only." >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "Nethance needs an Apple Silicon Mac for now." >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading Nethance..."
curl -fL --progress-bar -o "$tmp/Nethance.zip" https://github.com/masiur/nethance/releases/latest/download/Nethance.zip
ditto -x -k "$tmp/Nethance.zip" "$tmp"
# The app is not notarized yet; a copy downloaded with curl carries no quarantine flag, but clear it
# in case something added one.
xattr -dr com.apple.quarantine "$tmp/Nethance.app" 2>/dev/null || true

# Quit a running copy so it can be replaced. The engine keeps running; the new app offers its update.
osascript -e 'quit app id "app.nethance.Nethance"' 2>/dev/null || true
dest=/Applications/Nethance.app
sudo=
[ -w /Applications ] && { [ ! -e "$dest" ] || [ -w "$dest" ]; } || sudo=sudo
$sudo rm -rf "$dest"
$sudo mv "$tmp/Nethance.app" "$dest"
echo "Installed $dest"
open "$dest"
