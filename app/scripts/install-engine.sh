#!/bin/sh
# Installs the Netfuse engine as a root LaunchDaemon. The app runs this with administrator rights
# the first time it is switched on (and after an update changes the engine); by hand:
#   sudo install-engine.sh ENGINE_BINARY USER_HOME
#   sudo install-engine.sh --uninstall
#
# launchd starts the engine whenever USER_HOME/Library/Application Support/Netfuse/enabled exists
# (the app's on switch) and the engine stops itself once that file is gone.
set -eu
LABEL=app.netfuse.engine
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

launchctl bootout "system/$LABEL" 2>/dev/null || true # stops a running engine; it cleans up its routes
# bootout returns before the engine has exited, and loading it again until then fails
# ("Bootstrap failed: 5: Input/output error"): wait up to 10 s for it to go.
i=0
while launchctl print "system/$LABEL" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
if [ "${1:-}" = --uninstall ]; then
    rm -f "$BIN" "$PLIST"
    exit 0
fi
[ $# -eq 2 ] || { echo "usage: $0 ENGINE_BINARY USER_HOME | --uninstall" >&2; exit 2; }
DIR="$2/Library/Application Support/Netfuse"

# A root-owned copy, so no user process can swap the program that runs as root.
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$1" "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
		<string>run</string>
		<string>--rules</string><string>$DIR/rules.json</string>
		<string>--while</string><string>$DIR/enabled</string>
	</array>
	<key>KeepAlive</key>
	<dict>
		<key>PathState</key>
		<dict><key>$DIR/enabled</key><true/></dict>
	</dict>
	<key>StandardOutPath</key><string>/var/log/netfuse-engine.log</string>
	<key>StandardErrorPath</key><string>/var/log/netfuse-engine.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null
for _ in 1 2 3 4 5; do
    launchctl bootstrap system "$PLIST" 2>/dev/null && break
    sleep 1
done
launchctl print "system/$LABEL" >/dev/null 2>&1 || { launchctl bootstrap system "$PLIST"; exit 1; } # shows why
echo "installed $LABEL"
