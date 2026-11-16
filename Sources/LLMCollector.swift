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

    private struct RawQueueResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let position: Int
            let computer: String
            let program: String
            let model: String
            let path: String
            let waitSeconds: Double
        }
        let maxConcurrent: Int?
        let activeCount: Int?
        let queued: [Item]?
    }

    private var previousSamples: [String: SlotSample] = [:]
    private var pinnedTaskOwners: [String: SlotOwner] = [:]
    private var hostnameCache: [String: String] = [:]
    private let session: URLSession
    private let logPaths = [
        "/opt/homebrew/var/log/ollama.log",
        NSHomeDirectory() + "/.ollama/logs/server.log"
    ]
    private let hermesDBPath = NSHomeDirectory() + "/.hermes/state.db"
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
        let (clients, candidateOwners) = fetchConnectedClients()
        let slots = fetchSlots(
            ports: ports,
            logTimings: logTimings,
            candidateOwners: candidateOwners,
            now: now
        )
        let queued = fetchQueuedTasks()

        return MonitorSnapshot(
            timestamp: now,
            ollamaOnline: online || !ports.isEmpty,
            models: models,
            slots: slots,
            clients: clients,
            queuedTasks: queued
        )
    }

    func moveQueuedTask(id: String, direction: String) {
        guard let url = URL(string: "http://127.0.0.1:11434/_queue/move") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "direction": direction])
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { _, _, _ in
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.0)
    }

    private func fetchQueuedTasks() -> [QueuedTask] {
        guard let url = URL(string: "http://127.0.0.1:11434/_queue"),
              let data = syncGET(url: url),
              let decoded = try? JSONDecoder().decode(RawQueueResponse.self, from: data) else {
            return []
        }
        return (decoded.queued ?? []).map {
            QueuedTask(
                id: $0.id,
                position: $0.position,
                computer: $0.computer,
                program: $0.program,
                model: $0.model,
                path: $0.path,
                waitSeconds: $0.waitSeconds
            )
        }
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

    private func fetchSlots(
        ports: [Int],
        logTimings: [String: LogTiming],
        candidateOwners: [SlotOwner],
        now: Date
    ) -> [SlotInfo] {
        var decodedByPort: [(Int, [RawSlot])] = []
        var activeTaskKeys = Set<String>()
        var usedOwners = Set<SlotOwner>()

        for port in ports {
            guard let url = URL(string: "http://127.0.0.1:\(port)/slots"),
                  let data = syncGET(url: url),
                  let rawSlots = try? JSONDecoder().decode([RawSlot].self, from: data) else {
                continue
            }
            decodedByPort.append((port, rawSlots))
            for raw in rawSlots where raw.is_processing == true {
                let taskKey = "\(port)-\(raw.id)-\(raw.id_task ?? -1)"
                activeTaskKeys.insert(taskKey)
                if let pinned = pinnedTaskOwners[taskKey] {
                    // Refresh detail if a generic owner was pinned earlier and a specific one is now known
                    if pinned.detail == nil,
                       let better = candidateOwners.first(where: { $0.program == pinned.program && $0.detail != nil && !usedOwners.contains($0) }) {
                        pinnedTaskOwners[taskKey] = better
                        usedOwners.insert(better)
                    } else {
                        usedOwners.insert(pinned)
                    }
                }
            }
        }

        // Prune finished task pins
        pinnedTaskOwners = pinnedTaskOwners.filter { activeTaskKeys.contains($0.key) }

        var allSlots: [SlotInfo] = []
        var activeSampleKeys = Set<String>()

        for (port, rawSlots) in decodedByPort {
            for raw in rawSlots {
                let isProcessing = raw.is_processing ?? false
                let nDecoded = raw.next_token?.first?.n_decoded ?? 0
                let nPromptTokens = raw.n_prompt_tokens ?? 0
                let nPromptProcessed = raw.n_prompt_tokens_processed ?? 0
                let nCtx = raw.n_ctx ?? 0
                let taskId = raw.id_task
                let sampleKey = "\(port)-\(raw.id)-\(taskId ?? -1)"
                activeSampleKeys.insert(sampleKey)

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

                var owner: SlotOwner? = nil
                if isProcessing {
                    if let pinned = pinnedTaskOwners[sampleKey] {
                        owner = pinned
                    } else if let nextFree = candidateOwners.first(where: { !usedOwners.contains($0) }) {
                        owner = nextFree
                        usedOwners.insert(nextFree)
                        pinnedTaskOwners[sampleKey] = nextFree
                    } else if let fallback = candidateOwners.first {
                        owner = fallback
                        pinnedTaskOwners[sampleKey] = fallback
                    }
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
                        nCtx: nCtx,
                        owner: owner
                    )
                )
            }
        }

        previousSamples = previousSamples.filter { activeSampleKeys.contains($0.key) }
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

    // MARK: - Client & Sub-Session Discovery

    private func fetchConnectedClients() -> ([ClientSession], [SlotOwner]) {
        let lsofOutput = runCommand("/usr/sbin/lsof", args: [
            "-iTCP:11434",
            "-sTCP:ESTABLISHED",
            "-n", "-P",
            "-F", "pcn"
        ])

        var pidCommands: [Int32: String] = [:]
        var pidConnCounts: [Int32: Int] = [:]
        var remoteHostCounts: [String: Int] = [:]
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
                if currentCmd.lowercased() == "ollama" {
                    // Check for remote computer connections (peer IP != loopback)
                    if let remoteIP = extractRemotePeerIP(from: value), !isLoopback(remoteIP) {
                        let host = resolveHostname(for: remoteIP)
                        remoteHostCounts[host, default: 0] += 1
                    }
                } else if let pid = currentPid, pid != selfPid {
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
            var computer: String = ComputerInfo.name
            var details: [String] = []
        }

        var grouped: [String: GroupedClient] = [:]
        var candidateOwners: [SlotOwner] = []

        for pid in pids {
            let cmd = pidCommands[pid] ?? "Unknown"
            let args = pidArgs[pid] ?? cmd
            if args.contains("llm_queue_proxy.py") { continue }
            let (program, subDetail) = classifyClient(command: cmd, args: args)
            var entry = grouped[program] ?? GroupedClient()
            entry.count += pidConnCounts[pid] ?? 1
            entry.pids.append(pid)
            if let subDetail, !entry.details.contains(subDetail) {
                entry.details.append(subDetail)
            }
            grouped[program] = entry

            if program != "Hermes" {
                candidateOwners.append(SlotOwner(
                    computer: ComputerInfo.name,
                    program: program,
                    detail: subDetail
                ))
            }
        }

        // Enrich Hermes with live bot / session names from ~/.hermes/state.db
        if var hermesEntry = grouped["Hermes"] {
            let hermesDetails = fetchHermesActiveDetails()
            hermesEntry.details = hermesDetails
            grouped["Hermes"] = hermesEntry

            if hermesDetails.isEmpty {
                candidateOwners.insert(
                    SlotOwner(computer: ComputerInfo.name, program: "Hermes", detail: nil),
                    at: 0
                )
            } else {
                let hermesOwners = hermesDetails.map {
                    SlotOwner(computer: ComputerInfo.name, program: "Hermes", detail: $0)
                }
                candidateOwners.insert(contentsOf: hermesOwners, at: 0)
            }
        }

        // Add any remote computers connected over LAN
        for (remoteHost, count) in remoteHostCounts.sorted(by: { $0.key < $1.key }) {
            let key = "Remote (\(remoteHost))"
            grouped[key] = GroupedClient(
                count: count,
                pids: [],
                computer: remoteHost,
                details: ["LAN Client"]
            )
            candidateOwners.append(SlotOwner(
                computer: remoteHost,
                program: "Remote Client",
                detail: nil
            ))
        }

        var results: [ClientSession] = []

        for harness in knownHarnesses {
            if let entry = grouped.removeValue(forKey: harness) {
                results.append(ClientSession(
                    id: harness,
                    name: harness,
                    computer: entry.computer,
                    isConnected: true,
                    connectionCount: entry.count,
                    pids: entry.pids.sorted(),
                    isKnownHarness: true,
                    activeDetails: entry.details
                ))
            } else {
                results.append(ClientSession(
                    id: harness,
                    name: harness,
                    computer: ComputerInfo.name,
                    isConnected: false,
                    connectionCount: 0,
                    pids: [],
                    isKnownHarness: true,
                    activeDetails: []
                ))
            }
        }

        for (name, entry) in grouped.sorted(by: { $0.key < $1.key }) {
            results.append(ClientSession(
                id: name,
                name: name,
                computer: entry.computer,
                isConnected: true,
                connectionCount: entry.count,
                pids: entry.pids.sorted(),
                isKnownHarness: false,
                activeDetails: entry.details
            ))
        }

        results.sort {
            if $0.isConnected != $1.isConnected { return $0.isConnected && !$1.isConnected }
            return $0.name < $1.name
        }

        return (results, candidateOwners)
    }

    private func fetchHermesActiveDetails() -> [String] {
        guard FileManager.default.fileExists(atPath: hermesDBPath) else { return [] }

        let sql = """
        SELECT l.conversation_id, l.holder, COALESCE(s.source,''), COALESCE(s.display_name,''), COALESCE(s.title,'')
        FROM session_turn_leases l
        LEFT JOIN sessions s ON s.id = l.conversation_id
        WHERE l.expires_at > strftime('%s','now')
        ORDER BY l.acquired_at DESC;
        """

        let out = runCommand("/usr/bin/sqlite3", args: [
            "-readonly",
            "-separator", "\t",
            hermesDBPath,
            sql
        ])

        var details: [String] = []
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 5 else { continue }
            let convId = cols[0]
            let holder = cols[1]
            let source = cols[2].isEmpty ? "session" : cols[2]
            let displayName = cols[3]
            let title = cleanHermesTitle(cols[4])

            // Verify holder PID is still alive if present
            if let pid = extractHolderPid(holder), kill(pid, 0) != 0 {
                continue
            }

            let label: String
            if !displayName.isEmpty && !title.isEmpty && displayName != title {
                label = "\(source): \(displayName) (\(title))"
            } else if !title.isEmpty {
                label = "\(source): \(title)"
            } else if !displayName.isEmpty {
                label = "\(source): \(displayName)"
            } else {
                label = "\(source): \(String(convId.prefix(12)))"
            }

            if !details.contains(label) {
                details.append(label)
            }
        }

        if !details.isEmpty {
            return details
        }

        // Fallback: recently active sessions in last 30s
        let recentSql = """
        SELECT id, COALESCE(source,''), COALESCE(display_name,''), COALESCE(title,'')
        FROM sessions
        WHERE last_activity_at > strftime('%s','now') - 30
        ORDER BY last_activity_at DESC
        LIMIT 6;
        """
        let recentOut = runCommand("/usr/bin/sqlite3", args: [
            "-readonly",
            "-separator", "\t",
            hermesDBPath,
            recentSql
        ])
        for line in recentOut.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4 else { continue }
            let convId = cols[0]
            let source = cols[1].isEmpty ? "session" : cols[1]
            let displayName = cols[2]
            let title = cleanHermesTitle(cols[3])
            let name = !title.isEmpty ? title : (!displayName.isEmpty ? displayName : String(convId.prefix(12)))
            let label = "\(source): \(name)"
            if !details.contains(label) {
                details.append(label)
            }
        }

        return details
    }

    private func cleanHermesTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dotRange = s.range(of: " · ", options: .backwards) {
            let tail = s[dotRange.upperBound...]
            if tail.contains(":") {
                s = String(s[..<dotRange.lowerBound])
            }
        }
        if s.count > 40 {
            return String(s.prefix(38)) + "…"
        }
        return s
    }

    private func extractHolderPid(_ holder: String) -> Int32? {
        guard let r = holder.range(of: "pid=") else { return nil }
        let digits = holder[r.upperBound...].prefix(while: { $0.isNumber })
        return Int32(digits)
    }

    private func classifyClient(command: String, args: String) -> (String, String?) {
        let haystack = (command + " " + args).lowercased()
        if haystack.contains("hermes") {
            if haystack.contains("gateway") { return ("Hermes", "gateway") }
            if haystack.contains("hermes.app") { return ("Hermes", "desktop") }
            return ("Hermes", nil)
        }
        if haystack.contains("deepseek") || haystack.contains("dsh-desktop") {
            return ("DeepSeek Harness", haystack.contains("renderer") ? "desktop" : nil)
        }
        if haystack.contains("orca.app") || haystack.contains("application support/orca") {
            if haystack.contains("daemon-entry") { return ("Orca", "daemon") }
            if haystack.contains("renderer") { return ("Orca", "desktop") }
            return ("Orca", nil)
        }
        if haystack.contains("jarvis") {
            if haystack.contains("voice.mic") { return ("Jarvis", "voice") }
            if haystack.contains("serve") { return ("Jarvis", "server") }
            return ("Jarvis", nil)
        }
        if haystack.contains("lmstudio") { return ("LM Studio", nil) }
        if haystack.contains("open-webui") { return ("Open WebUI", nil) }
        if haystack.contains("cursor") { return ("Cursor", nil) }
        if haystack.contains("claude") { return ("Claude", nil) }
        return (command, nil)
    }

    // MARK: - Network Helpers

    private func extractRemotePeerIP(from lsofName: String) -> String? {
        guard let arrow = lsofName.range(of: "->") else { return nil }
        let peer = String(lsofName[arrow.upperBound...])
        if peer.hasPrefix("[") {
            if let closeBracket = peer.firstIndex(of: "]") {
                return String(peer[peer.index(after: peer.startIndex)..<closeBracket])
            }
        }
        if let colon = peer.lastIndex(of: ":") {
            return String(peer[..<colon])
        }
        return peer
    }

    private func isLoopback(_ ip: String) -> Bool {
        ip == "127.0.0.1" || ip == "::1" || ip == "localhost"
    }

    private func resolveHostname(for ip: String) -> String {
        if let cached = hostnameCache[ip] { return cached }
        var resolved = ip
        if let host = Host(address: ip).name {
            let short = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
            if !short.isEmpty {
                resolved = short
            }
        }
        hostnameCache[ip] = resolved
        return resolved
    }

    // MARK: - Process & HTTP Helpers

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
