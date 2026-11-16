#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$ROOT_DIR/build.sh"

rm -rf /Applications/LocalLLMMonitor.app
cp -R "$ROOT_DIR/LocalLLMMonitor.app" /Applications/LocalLLMMonitor.app

mkdir -p "$HOME/.local/share/llm-queue-proxy"
cp "$ROOT_DIR/QueueProxy/llm_queue_proxy.py" "$HOME/.local/share/llm-queue-proxy/llm_queue_proxy.py"

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
if launchctl print "gui/$UID_NUM/com.local.llm-monitor" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$UID_NUM/com.local.llm-monitor"
else
    launchctl bootstrap "gui/$UID_NUM" "$PLIST"
fi

echo "Installed and running from /Applications/LocalLLMMonitor.app"
