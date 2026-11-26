#!/bin/sh
# Builds Nethance.app (menu-bar only, ad-hoc signed) into build/. Usage: scripts/bundle.sh [--open]
set -eu
cd "$(dirname "$0")/.."
swift build -c release
app=build/Nethance.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Nethance" "$app/Contents/MacOS/Nethance"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>app.nethance.Nethance</string>
	<key>CFBundleName</key><string>Nethance</string>
	<key>CFBundleExecutable</key><string>Nethance</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict>
</plist>
EOF
# Figtree (Astryx's typeface) is used when its .ttf files sit in Resources/Fonts; otherwise the
# system font stands in.
if [ -d Resources/Fonts ]; then cp -R Resources/Fonts "$app/Contents/Resources/"; fi
codesign --force --sign - "$app"
echo "built $app"
if [ "${1:-}" = "--open" ]; then open "$app"; fi
