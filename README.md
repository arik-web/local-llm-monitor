# Local LLM Monitor

A lightweight macOS menubar widget that monitors local Ollama / `llama-server` inference in real time.

## Features

- **Menubar Live Status**: Active session count and total tokens/sec (`gen t/s` or `pp/s`).
- **Per-Slot Breakdown**: Live phase (`Generating` / `Prompt Eval`), individual tokens/sec, decoded tokens, and context usage.
- **Connected Clients**: Identifies which apps have active sessions with Ollama (`Hermes`, `DeepSeek Harness`, `Orca`, and other local clients).
- **Usage Report (`1H`, `24H`, `7D`, `30D`)**:
  - Hourly / interval token usage stacked by client.
  - Parallel slot concurrency over time and concurrency split (`1 slot` vs `2+ slots`).
  - Client and model breakdowns with tokens, requests, active time, and average speed.
  - Persists 31 days of history in `~/Library/Application Support/LocalLLMMonitor/usage_history.json` and backfills prior entries from `/opt/homebrew/var/log/ollama.log`.

## Build, Install, and Run

```zsh
chmod +x build.sh install.sh
./install.sh
```

`install.sh` compiles `LocalLLMMonitor.app`, installs it to `/Applications/LocalLLMMonitor.app`, and registers a `LaunchAgent` (`com.local.llm-monitor`) so it starts on login.
