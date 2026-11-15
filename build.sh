#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/LocalLLMMonitor.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

mkdir -p "$MACOS_DIR"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

swiftc -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  -framework Charts \
  "$ROOT_DIR/Sources/Models.swift" \
  "$ROOT_DIR/Sources/LLMCollector.swift" \
  "$ROOT_DIR/Sources/UsageHistory.swift" \
  "$ROOT_DIR/Sources/ReportView.swift" \
  "$ROOT_DIR/Sources/MonitorView.swift" \
  "$ROOT_DIR/Sources/main.swift" \
  -o "$MACOS_DIR/LocalLLMMonitor"

echo "Built $APP_DIR"

if [[ "${1:-}" != "--no-push" ]] && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
    if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
      git -C "$ROOT_DIR" add -A
      git -C "$ROOT_DIR" commit -m "Build $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    git -C "$ROOT_DIR" push origin HEAD
  fi
fi
