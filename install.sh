#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$ROOT_DIR/build.sh"

rm -rf /Applications/LocalLLMMonitor.app
cp -R "$ROOT_DIR/LocalLLMMonitor.app" /Applications/LocalLLMMonitor.app

PLIST="$HOME/Library/LaunchAgents/com.local.llm-monitor.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.llm-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/LocalLLMMonitor.app/Contents/MacOS/LocalLLMMonitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

UID_NUM=$(id -u)
launchctl bootout "gui/$UID_NUM/com.local.llm-monitor" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

echo "Installed and running from /Applications/LocalLLMMonitor.app"
