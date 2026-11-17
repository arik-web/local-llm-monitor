# llm widgt (Local LLM Monitor)

macOS menu-bar widget that shows live local Ollama / `llama-server` inference and usage history. Used by the owner on this Mac.

## Stack
- Swift, AppKit + SwiftUI + Charts, compiled with plain `swiftc` (no Xcode project). macOS 14.0 minimum (`Info.plist`).
- Bundle id and LaunchAgent label: `com.local.llm-monitor`. App version 1.0.
- `QueueProxy/llm_queue_proxy.py`: Python 3 standard library, no dependencies.

## Commands
- Build only, no git side effects: `./build.sh --no-push`
- Build + install to `/Applications` + register LaunchAgent: `./install.sh`
- No tests exist.

## Layout
- `Sources/LLMCollector.swift`: polls Ollama, `llama-server` slots, the queue proxy and the Ollama log.
- `Sources/UsageHistory.swift`: 31-day history in `~/Library/Application Support/LocalLLMMonitor/usage_history.json`.
- `Sources/MonitorView.swift`, `Sources/ReportView.swift`: menu-bar panel and 1H/24H/7D/30D report.
- `Sources/Models.swift`, `Sources/main.swift`: data types and app entry.
- `QueueProxy/llm_queue_proxy.py`: priority-queue proxy in front of Ollama.
- `build.sh`, `install.sh`, `Info.plist`.

## Gotchas
- `build.sh` without `--no-push` runs `git add -A`, commits "Build <date>" and pushes to `origin` (GitHub `arik-web/local-llm-monitor`). `install.sh` calls `build.sh` with no argument, so it also commits and pushes. Run `./build.sh --no-push` unless the owner asked for a push.
- The queue proxy listens on 127.0.0.1:11434 and forwards to 127.0.0.1:11436. With it in use, Ollama must run on 11436.
- Proxy env names: `LLM_QUEUE_LISTEN_HOST`, `LLM_QUEUE_LISTEN_PORT`, `LLM_QUEUE_UPSTREAM_HOST`, `LLM_QUEUE_UPSTREAM_PORT`, `OLLAMA_NUM_PARALLEL` (default 4).
- `install.sh` copies the proxy to `~/.local/share/llm-queue-proxy/` but does not create a launchd job for it.
- The app reads `/opt/homebrew/var/log/ollama.log` and `~/.ollama/logs/server.log` for backfill and timings.
- The app expects the queue proxy endpoints `/_queue` and `/_queue/move` on port 11434.
- `LocalLLMMonitor.app/` is a build output and git-ignored.

## Rules
- Ask before any push. Use `--no-push` by default.
- Never commit secrets. Credentials go through the `sil` CLI / `secret-input-layer` MCP.
