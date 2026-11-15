import Foundation

final class LLMCollector {
    private struct SlotSample {
        let timestamp: Date
        let nDecoded: Int
        let nPromptProcessed: Int
    }

    private struct LogTiming {
        var genTps: Double?
        var promptTps: Double?
    }

    private struct RawPsResponse: Decodable {
        struct Model: Decodable {
            struct Details: Decodable {
                let parameter_size: String?
                let quantization_level: String?
            }
            let name: String
            let size_vram: Int64?
            let context_length: Int?
            let runner: String?
            let details: Details?
        }
        let models: [Model]?
    }

    private struct RawSlot: Decodable {
        struct NextToken: Decodable {
            let n_decoded: Int?
        }
        let id: Int
        let id_task: Int?
        let is_processing: Bool?
        let n_ctx: Int?
        let n_prompt_tokens: Int?
        let n_prompt_tokens_processed: Int?
        let next_token: [NextToken]?
    }

    private var previousSamples: [String: SlotSample] = [:]
    private let session: URLSession
    private let logPaths = [
        "/opt/homebrew/var/log/ollama.log",
        NSHomeDirectory() + "/.ollama/logs/server.log"
    ]
    private let knownHarnesses = ["Hermes", "DeepSeek Harness", "Orca"]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 1.5
        self.session = URLSession(configuration: config)
    }

    func collect() -> MonitorSnapshot {
        let now = Date()
        let (online, models) = fetchOllamaModels()
        let ports = discoverLlamaServerPorts()
        let logTimings = readRecentLogTimings()
        let slots = fetchSlots(ports: ports, logTimings: logTimings, now: now)
        let clients = fetchConnectedClients()

        return MonitorSnapshot(
            timestamp: now,
            ollamaOnline: online || !ports.isEmpty,
            models: models,
            slots: slots,
            clients: clients
        )
    }

    // MARK: - Ollama /api/ps

    private func fetchOllamaModels() -> (Bool, [LoadedModelInfo]) {
        guard let url = URL(string: "http://127.0.0.1:11434/api/ps"),
              let data = syncGET(url: url) else {
            return (false, [])
        }
        guard let decoded = try? JSONDecoder().decode(RawPsResponse.self, from: data) else {
            return (true, [])
        }
        let models = (decoded.models ?? []).map { m in
            LoadedModelInfo(
                id: m.name,
                name: m.name,
                parameterSize: m.details?.parameter_size ?? "",
                quantization: m.details?.quantization_level ?? "",
                sizeVramBytes: m.size_vram ?? 0,
                contextLength: m.context_length ?? 0,
                runner: m.runner ?? "llamacpp"
            )
        }
        return (true, models)
    }

    // MARK: - Runner Discovery & /slots

    private func discoverLlamaServerPorts() -> [Int] {
        let output = runCommand("/bin/ps", args: ["-ax", "-o", "pid=,args="])
        var ports: [Int] = []
        for line in output.split(separator: "\n") {
            let str = String(line)
            guard str.contains("llama-server") else { continue }
            let tokens = str.split(whereSeparator: { $0.isWhitespace })
            for i in 0..<(tokens.count - 1) {
                if tokens[i] == "--port", let port = Int(tokens[i + 1]), !ports.contains(port) {
                    ports.append(port)
                }
            }
        }
        return ports.sorted()
    }

    private func fetchSlots(ports: [Int], logTimings: [String: LogTiming], now: Date) -> [SlotInfo] {
        var allSlots: [SlotInfo] = []
        var activeKeys = Set<String>()

        for port in ports {
            guard let url = URL(string: "http://127.0.0.1:\(port)/slots"),
                  let data = syncGET(url: url),
                  let rawSlots = try? JSONDecoder().decode([RawSlot].self, from: data) else {
                continue
            }

            for raw in rawSlots {
                let isProcessing = raw.is_processing ?? false
                let nDecoded = raw.next_token?.first?.n_decoded ?? 0
                let nPromptTokens = raw.n_prompt_tokens ?? 0
                let nPromptProcessed = raw.n_prompt_tokens_processed ?? 0
                let nCtx = raw.n_ctx ?? 0
                let taskId = raw.id_task
                let sampleKey = "\(port)-\(raw.id)-\(taskId ?? -1)"
                activeKeys.insert(sampleKey)

                var deltaGenTps = 0.0
                var deltaPromptTps = 0.0

                if let prev = previousSamples[sampleKey] {
                    let dt = now.timeIntervalSince(prev.timestamp)
                    if dt >= 0.25 && dt <= 10.0 {
                        let genDelta = max(0, nDecoded - prev.nDecoded)
                        let promptDelta = max(0, nPromptProcessed - prev.nPromptProcessed)
                        deltaGenTps = Double(genDelta) / dt
                        deltaPromptTps = Double(promptDelta) / dt
                    }
                }

                previousSamples[sampleKey] = SlotSample(
                    timestamp: now,
                    nDecoded: nDecoded,
                    nPromptProcessed: nPromptProcessed
                )

                let timingKey = "\(raw.id)-\(taskId ?? -1)"
                let logTiming = logTimings[timingKey]

                let phase: SlotPhase
                let finalGenTps: Double
                let finalPromptTps: Double

                if !isProcessing {
                    phase = .idle
                    finalGenTps = 0
                    finalPromptTps = 0
                } else if nDecoded > 0 || deltaGenTps > 0 {
                    phase = .generating
                    finalGenTps = deltaGenTps > 0 ? deltaGenTps : (logTiming?.genTps ?? 0)
                    finalPromptTps = 0
                } else if nPromptProcessed > 0 || deltaPromptTps > 0 {
                    phase = .promptEval
                    finalGenTps = 0
                    finalPromptTps = deltaPromptTps > 0 ? deltaPromptTps : (logTiming?.promptTps ?? 0)
                } else {
                    phase = .starting
                    finalGenTps = 0
                    finalPromptTps = 0
                }

                allSlots.append(
                    SlotInfo(
                        id: "\(port)-\(raw.id)",
                        slotId: raw.id,
                        port: port,
                        taskId: taskId,
                        isProcessing: isProcessing,
                        phase: phase,
                        genTps: finalGenTps,
                        promptTps: finalPromptTps,
                        nDecoded: nDecoded,
                        nPromptTokens: nPromptTokens,
                        nPromptProcessed: nPromptProcessed,
                        nCtx: nCtx
                    )
                )
            }
        }

        // Prune stale samples
        previousSamples = previousSamples.filter { activeKeys.contains($0.key) }
        return allSlots.sorted { ($0.port, $0.slotId) < ($1.port, $1.slotId) }
    }

    // MARK: - Ollama Log Timings

    private func readRecentLogTimings() -> [String: LogTiming] {
        var timings: [String: LogTiming] = [:]
        guard let path = logPaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let handle = FileHandle(forReadingAtPath: path) else {
            return timings
        }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let tailBytes: UInt64 = 65_536
        if fileSize > tailBytes {
            handle.seek(toFileOffset: fileSize - tailBytes)
        } else {
            handle.seek(toFileOffset: 0)
        }

        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return timings }

        for line in text.split(separator: "\n") {
            let s = String(line)
            guard s.contains("slot print_timing:") else { continue }
            guard let slotId = extractFirstInt(in: s, after: "id"),
                  let taskId = extractFirstInt(in: s, after: "task") else {
                continue
            }
            let key = "\(slotId)-\(taskId)"
            var entry = timings[key] ?? LogTiming()

            if let tg3s = extractFirstDouble(in: s, after: "tg_3s =") {
                entry.genTps = tg3s
            } else if let tg = extractFirstDouble(in: s, after: "tg =") {
                entry.genTps = tg
            }

            if s.contains("prompt processing"), let pp = extractFirstDouble(in: s, after: "/") {
                entry.promptTps = pp
            }

            timings[key] = entry
        }
        return timings
    }

    // MARK: - Client Discovery (lsof + ps)

    private func fetchConnectedClients() -> [ClientSession] {
        let lsofOutput = runCommand("/usr/sbin/lsof", args: [
            "-iTCP:11434",
            "-sTCP:ESTABLISHED",
            "-n", "-P",
            "-F", "pcn"
        ])

        var pidCommands: [Int32: String] = [:]
        var pidConnCounts: [Int32: Int] = [:]
        var currentPid: Int32?
        var currentCmd = ""
        let selfPid = ProcessInfo.processInfo.processIdentifier

        for rawLine in lsofOutput.split(separator: "\n") {
            guard let prefix = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch prefix {
            case "p":
                currentPid = Int32(value)
                currentCmd = ""
            case "c":
                currentCmd = value
                if let pid = currentPid {
                    pidCommands[pid] = value
                }
            case "n":
                // Count only client side (exclude ollama server and this monitor app)
                if let pid = currentPid, pid != selfPid, currentCmd.lowercased() != "ollama" {
                    pidConnCounts[pid, default: 0] += 1
                }
            default:
                break
            }
        }

        let pids = Array(pidConnCounts.keys)
        var pidArgs: [Int32: String] = [:]
        if !pids.isEmpty {
            let pidList = pids.map(String.init).joined(separator: ",")
            let psOut = runCommand("/bin/ps", args: ["-p", pidList, "-o", "pid=,args="])
            for line in psOut.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let spaceIdx = trimmed.firstIndex(where: { $0.isWhitespace }),
                      let pid = Int32(trimmed[..<spaceIdx]) else {
                    continue
                }
                let args = String(trimmed[spaceIdx...]).trimmingCharacters(in: .whitespaces)
                pidArgs[pid] = args
            }
        }

        struct GroupedClient {
            var count: Int = 0
            var pids: [Int32] = []
        }

        var grouped: [String: GroupedClient] = [:]
        for pid in pids {
            let cmd = pidCommands[pid] ?? "Unknown"
            let args = pidArgs[pid] ?? cmd
            let name = classifyClient(command: cmd, args: args)
            var entry = grouped[name] ?? GroupedClient()
            entry.count += pidConnCounts[pid] ?? 1
            entry.pids.append(pid)
            grouped[name] = entry
        }

        var results: [ClientSession] = []

        // Known harnesses first (connected or idle)
        for harness in knownHarnesses {
            if let entry = grouped.removeValue(forKey: harness) {
                results.append(ClientSession(
                    id: harness,
                    name: harness,
                    isConnected: true,
                    connectionCount: entry.count,
                    pids: entry.pids.sorted(),
                    isKnownHarness: true
                ))
            } else {
                results.append(ClientSession(
                    id: harness,
                    name: harness,
                    isConnected: false,
                    connectionCount: 0,
                    pids: [],
                    isKnownHarness: true
                ))
            }
        }

        // Any other connected clients
        for (name, entry) in grouped.sorted(by: { $0.key < $1.key }) {
            results.append(ClientSession(
                id: name,
                name: name,
                isConnected: true,
                connectionCount: entry.count,
                pids: entry.pids.sorted(),
                isKnownHarness: false
            ))
        }

        return results.sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected && !$1.isConnected }
            return $0.name < $1.name
        }
    }

    private func classifyClient(command: String, args: String) -> String {
        let haystack = (command + " " + args).lowercased()
        if haystack.contains("hermes") { return "Hermes" }
        if haystack.contains("deepseek") || haystack.contains("dsh-desktop") { return "DeepSeek Harness" }
        if haystack.contains("orca.app") || haystack.contains("application support/orca") { return "Orca" }
        if haystack.contains("jarvis") { return "Jarvis" }
        if haystack.contains("lmstudio") { return "LM Studio" }
        if haystack.contains("open-webui") { return "Open WebUI" }
        if haystack.contains("cursor") { return "Cursor" }
        if haystack.contains("claude") { return "Claude" }
        return command
    }

    // MARK: - Helpers

    private func syncGET(url: URL) -> Data? {
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = data
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 1.2)
        return result
    }

    private func runCommand(_ launchPath: String, args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func extractFirstInt(in line: String, after marker: String) -> Int? {
        guard let range = line.range(of: marker) else { return nil }
        let suffix = line[range.upperBound...].drop(while: { $0 == " " || $0 == "=" })
        let digits = suffix.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private func extractFirstDouble(in line: String, after marker: String) -> Double? {
        guard let range = line.range(of: marker) else { return nil }
        let suffix = line[range.upperBound...].drop(while: { $0 == " " })
        let numStr = suffix.prefix(while: { $0.isNumber || $0 == "." })
        return Double(numStr)
    }
}
