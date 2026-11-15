import Foundation

enum ReportTimeframe: String, CaseIterable, Identifiable {
    case hour1 = "1H"
    case hours24 = "24H"
    case week = "7D"
    case month = "30D"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour1: return "Last Hour"
        case .hours24: return "Last 24 Hours"
        case .week: return "Last 7 Days"
        case .month: return "Last 30 Days"
        }
    }

    var hours: Int {
        switch self {
        case .hour1: return 1
        case .hours24: return 24
        case .week: return 24 * 7
        case .month: return 24 * 30
        }
    }

    var chartIntervalSeconds: TimeInterval {
        switch self {
        case .hour1: return 300       // 5 minutes
        case .hours24: return 3600   // 1 hour
        case .week: return 21600     // 6 hours
        case .month: return 86400    // 1 day
        }
    }
}

struct UsageBucket: Codable, Equatable {
    let hourEpoch: TimeInterval
    let client: String
    let model: String
    var genTokens: Int
    var promptTokens: Int
    var activeSeconds: Double
    var requestCount: Int
    var tpsSum: Double
    var tpsSamples: Int
}

struct ConcurrencyBucket: Codable, Equatable {
    let bucketEpoch: TimeInterval
    var slotCounts: [Int: Int]
    var maxParallel: Int
    var configuredSlots: Int
    var activeSeconds: Double
}

private struct UsageHistoryPayload: Codable {
    let buckets: [UsageBucket]
    let concurrency: [ConcurrencyBucket]
}

struct ClientUsageSummary: Identifiable {
    let id: String
    let client: String
    let genTokens: Int
    let promptTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let activeSeconds: Double
    let avgGenTps: Double
    let shareRatio: Double
}

struct ModelUsageSummary: Identifiable {
    let id: String
    let model: String
    let genTokens: Int
    let promptTokens: Int
    let totalTokens: Int
    let requestCount: Int
    let activeSeconds: Double
}

struct TimeClientPoint: Identifiable {
    let id: String
    let timestamp: Date
    let client: String
    let totalTokens: Int
    let genTokens: Int
    let promptTokens: Int
}

struct ParallelSlotPoint: Identifiable {
    let id: String
    let timestamp: Date
    let avgParallel: Double
    let maxParallel: Int
}

struct ConcurrencySlice: Identifiable {
    let id: Int
    let parallelCount: Int
    let label: String
    let seconds: Double
    let ratio: Double
}

struct UsageReport {
    let generatedAt: Date
    let timeframe: ReportTimeframe
    let totalGenTokens: Int
    let totalPromptTokens: Int
    let totalTokens: Int
    let totalRequests: Int
    let totalActiveSeconds: Double
    let avgGenTps: Double
    let peakParallelSlots: Int
    let avgParallelSlots: Double
    let configuredSlots: Int
    let timePoints: [TimeClientPoint]
    let parallelPoints: [ParallelSlotPoint]
    let concurrencySlices: [ConcurrencySlice]
    let clientSummaries: [ClientUsageSummary]
    let modelSummaries: [ModelUsageSummary]
}

final class UsageStore {
    private struct SlotCursor {
        let taskId: Int?
        let nDecoded: Int
        let nPromptProcessed: Int
        let timestamp: Date
    }

    private var buckets: [String: UsageBucket] = [:]
    private var concurrencyBuckets: [TimeInterval: ConcurrencyBucket] = [:]
    private var cursors: [String: SlotCursor] = [:]
    private var lastPollTimestamp: Date?
    private var lastFlush = Date()
    private let queue = DispatchQueue(label: "com.local.llm-monitor.usage", qos: .utility)
    private let storageURL: URL
    private let logPaths = [
        "/opt/homebrew/var/log/ollama.log",
        NSHomeDirectory() + "/.ollama/logs/server.log"
    ]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LocalLLMMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("usage_history.json")
        loadFromDisk()
    }

    func record(snapshot: MonitorSnapshot) {
        queue.async { [weak self] in
            self?.recordLocked(snapshot: snapshot)
        }
    }

    func flush() {
        queue.sync {
            saveToDiskLocked()
        }
    }

    func buildReport(timeframe: ReportTimeframe = .hours24) -> UsageReport {
        queue.sync {
            let now = Date()
            let cutoff = now.addingTimeInterval(-Double(timeframe.hours) * 3600.0)
            let cutoffEpoch = floorInterval(cutoff, seconds: 300).timeIntervalSince1970

            var combinedBuckets = buckets.values.filter { $0.hourEpoch >= cutoffEpoch }
            var combinedConcurrency = concurrencyBuckets.values.filter { $0.bucketEpoch >= cutoffEpoch }

            let recordedHours = Set(combinedBuckets.map { floorInterval(Date(timeIntervalSince1970: $0.hourEpoch), seconds: 3600).timeIntervalSince1970 })

            let (logBuckets, logConcurrency) = parseOllamaLogBackfill(since: cutoff, excludingHours: recordedHours)
            combinedBuckets.append(contentsOf: logBuckets)
            combinedConcurrency.append(contentsOf: logConcurrency)

            return aggregate(
                buckets: combinedBuckets,
                concurrency: combinedConcurrency,
                now: now,
                timeframe: timeframe
            )
        }
    }

    // MARK: - Live Recording

    private func recordLocked(snapshot: MonitorSnapshot) {
        let now = snapshot.timestamp
        let bucketEpoch = floorInterval(now, seconds: 300).timeIntervalSince1970
        let modelName = snapshot.models.first?.name ?? "Unknown Model"

        let pollDt: Double
        if let prevPoll = lastPollTimestamp {
            let elapsed = now.timeIntervalSince(prevPoll)
            pollDt = (elapsed > 0 && elapsed < 10.0) ? elapsed : 1.5
        } else {
            pollDt = 1.5
        }
        lastPollTimestamp = now

        // Record parallel slot concurrency
        let activeCount = snapshot.activeSessionCount
        let configuredCount = max(snapshot.slots.count, activeCount)
        if activeCount > 0 {
            var cb = concurrencyBuckets[bucketEpoch] ?? ConcurrencyBucket(
                bucketEpoch: bucketEpoch,
                slotCounts: [:],
                maxParallel: 0,
                configuredSlots: configuredCount,
                activeSeconds: 0
            )
            cb.slotCounts[activeCount, default: 0] += 1
            cb.maxParallel = max(cb.maxParallel, activeCount)
            cb.configuredSlots = max(cb.configuredSlots, configuredCount)
            cb.activeSeconds += pollDt
            concurrencyBuckets[bucketEpoch] = cb
        }

        let connectedClients = snapshot.clients.filter { $0.isConnected }.map { $0.name }
        let targetClients = connectedClients.isEmpty ? ["Local / Other"] : connectedClients
        let shareCount = targetClients.count

        var activeKeys = Set<String>()

        for slot in snapshot.slots {
            let key = "\(slot.port)-\(slot.slotId)"
            activeKeys.insert(key)

            let prev = cursors[key]
            let isNewTask = (slot.taskId != nil && slot.taskId != prev?.taskId && slot.isProcessing)

            var deltaGen = 0
            var deltaPrompt = 0
            var dt = 0.0

            if let prev, prev.taskId == slot.taskId {
                deltaGen = max(0, slot.nDecoded - prev.nDecoded)
                deltaPrompt = max(0, slot.nPromptProcessed - prev.nPromptProcessed)
                let elapsed = now.timeIntervalSince(prev.timestamp)
                if slot.isProcessing && elapsed > 0 && elapsed < 10.0 {
                    dt = elapsed
                }
            } else if slot.isProcessing {
                deltaGen = max(0, slot.nDecoded)
                deltaPrompt = max(0, slot.nPromptProcessed)
            }

            cursors[key] = SlotCursor(
                taskId: slot.taskId,
                nDecoded: slot.nDecoded,
                nPromptProcessed: slot.nPromptProcessed,
                timestamp: now
            )

            guard deltaGen > 0 || deltaPrompt > 0 || isNewTask || dt > 0 else { continue }

            for (idx, client) in targetClients.enumerated() {
                let genShare = splitInt(deltaGen, parts: shareCount, index: idx)
                let promptShare = splitInt(deltaPrompt, parts: shareCount, index: idx)
                let reqShare = (isNewTask && idx == 0) ? 1 : 0
                let dtShare = dt / Double(shareCount)

                let bucketKey = "\(Int64(bucketEpoch))|\(client)|\(modelName)"
                var b = buckets[bucketKey] ?? UsageBucket(
                    hourEpoch: bucketEpoch,
                    client: client,
                    model: modelName,
                    genTokens: 0,
                    promptTokens: 0,
                    activeSeconds: 0,
                    requestCount: 0,
                    tpsSum: 0,
                    tpsSamples: 0
                )
                b.genTokens += genShare
                b.promptTokens += promptShare
                b.activeSeconds += dtShare
                b.requestCount += reqShare
                if slot.phase == .generating && slot.genTps > 0 {
                    b.tpsSum += slot.genTps
                    b.tpsSamples += 1
                }
                buckets[bucketKey] = b
            }
        }

        cursors = cursors.filter { activeKeys.contains($0.key) }

        if now.timeIntervalSince(lastFlush) >= 15.0 {
            pruneOldBucketsLocked(now: now)
            saveToDiskLocked()
            lastFlush = now
        }
    }

    // MARK: - Aggregation

    private func aggregate(
        buckets: [UsageBucket],
        concurrency: [ConcurrencyBucket],
        now: Date,
        timeframe: ReportTimeframe
    ) -> UsageReport {
        var totalGen = 0
        var totalPrompt = 0
        var totalReq = 0
        var totalSec = 0.0
        var totalTpsSum = 0.0
        var totalTpsSamples = 0

        struct ClientAcc {
            var gen = 0
            var prompt = 0
            var req = 0
            var sec = 0.0
            var tpsSum = 0.0
            var tpsSamples = 0
        }
        struct ModelAcc {
            var gen = 0
            var prompt = 0
            var req = 0
            var sec = 0.0
        }

        var clientMap: [String: ClientAcc] = [:]
        var modelMap: [String: ModelAcc] = [:]
        var timeMap: [String: (ts: Date, client: String, gen: Int, prompt: Int)] = [:]
        let stepSeconds = timeframe.chartIntervalSeconds

        for b in buckets {
            totalGen += b.genTokens
            totalPrompt += b.promptTokens
            totalReq += b.requestCount
            totalSec += b.activeSeconds
            totalTpsSum += b.tpsSum
            totalTpsSamples += b.tpsSamples

            var ca = clientMap[b.client] ?? ClientAcc()
            ca.gen += b.genTokens
            ca.prompt += b.promptTokens
            ca.req += b.requestCount
            ca.sec += b.activeSeconds
            ca.tpsSum += b.tpsSum
            ca.tpsSamples += b.tpsSamples
            clientMap[b.client] = ca

            var ma = modelMap[b.model] ?? ModelAcc()
            ma.gen += b.genTokens
            ma.prompt += b.promptTokens
            ma.req += b.requestCount
            ma.sec += b.activeSeconds
            modelMap[b.model] = ma

            let chartDate = floorInterval(Date(timeIntervalSince1970: b.hourEpoch), seconds: stepSeconds)
            let tKey = "\(Int64(chartDate.timeIntervalSince1970))|\(b.client)"
            var ta = timeMap[tKey] ?? (chartDate, b.client, 0, 0)
            ta.gen += b.genTokens
            ta.prompt += b.promptTokens
            timeMap[tKey] = ta
        }

        // Concurrency aggregation
        struct ParallelAcc {
            var weightedSum = 0.0
            var sampleCount = 0
            var maxParallel = 0
        }
        var parallelMap: [TimeInterval: ParallelAcc] = [:]
        var globalSlotCounts: [Int: Double] = [:]
        var peakParallel = 0
        var maxConfigured = 0
        var globalWeightedSlots = 0.0
        var globalSamples = 0

        for cb in concurrency {
            peakParallel = max(peakParallel, cb.maxParallel)
            maxConfigured = max(maxConfigured, cb.configuredSlots)

            let chartEpoch = floorInterval(Date(timeIntervalSince1970: cb.bucketEpoch), seconds: stepSeconds).timeIntervalSince1970
            var pa = parallelMap[chartEpoch] ?? ParallelAcc()
            pa.maxParallel = max(pa.maxParallel, cb.maxParallel)

            let totalSamplesInBucket = cb.slotCounts.values.reduce(0, +)
            for (slotCount, count) in cb.slotCounts {
                pa.weightedSum += Double(slotCount * count)
                pa.sampleCount += count
                globalWeightedSlots += Double(slotCount * count)
                globalSamples += count

                let secShare = totalSamplesInBucket > 0
                    ? cb.activeSeconds * (Double(count) / Double(totalSamplesInBucket))
                    : 0
                globalSlotCounts[slotCount, default: 0] += secShare
            }
            parallelMap[chartEpoch] = pa
        }

        let parallelPoints = parallelMap.map { (epoch, acc) in
            ParallelSlotPoint(
                id: "\(Int64(epoch))",
                timestamp: Date(timeIntervalSince1970: epoch),
                avgParallel: acc.sampleCount > 0 ? acc.weightedSum / Double(acc.sampleCount) : 0,
                maxParallel: acc.maxParallel
            )
        }.sorted { $0.timestamp < $1.timestamp }

        let totalConcurrentSec = globalSlotCounts.values.reduce(0, +)
        let concurrencySlices = globalSlotCounts.keys.sorted().map { count -> ConcurrencySlice in
            let sec = globalSlotCounts[count] ?? 0
            let ratio = totalConcurrentSec > 0 ? sec / totalConcurrentSec : 0
            return ConcurrencySlice(
                id: count,
                parallelCount: count,
                label: count == 1 ? "1 slot" : "\(count) slots",
                seconds: sec,
                ratio: ratio
            )
        }

        let avgParallel = globalSamples > 0 ? globalWeightedSlots / Double(globalSamples) : 0
        let totalTokens = totalGen + totalPrompt

        let clientSummaries = clientMap.map { (name, acc) in
            let tot = acc.gen + acc.prompt
            let avgTps = acc.tpsSamples > 0 ? acc.tpsSum / Double(acc.tpsSamples) : 0
            let ratio = totalTokens > 0 ? Double(tot) / Double(totalTokens) : 0
            return ClientUsageSummary(
                id: name,
                client: name,
                genTokens: acc.gen,
                promptTokens: acc.prompt,
                totalTokens: tot,
                requestCount: acc.req,
                activeSeconds: acc.sec,
                avgGenTps: avgTps,
                shareRatio: ratio
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        let modelSummaries = modelMap.map { (name, acc) in
            ModelUsageSummary(
                id: name,
                model: name,
                genTokens: acc.gen,
                promptTokens: acc.prompt,
                totalTokens: acc.gen + acc.prompt,
                requestCount: acc.req,
                activeSeconds: acc.sec
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        let timePoints = timeMap.map { (key, val) in
            TimeClientPoint(
                id: key,
                timestamp: val.ts,
                client: val.client,
                totalTokens: val.gen + val.prompt,
                genTokens: val.gen,
                promptTokens: val.prompt
            )
        }.sorted { ($0.timestamp, $0.client) < ($1.timestamp, $1.client) }

        let avgTps = totalTpsSamples > 0 ? totalTpsSum / Double(totalTpsSamples) : 0

        return UsageReport(
            generatedAt: now,
            timeframe: timeframe,
            totalGenTokens: totalGen,
            totalPromptTokens: totalPrompt,
            totalTokens: totalTokens,
            totalRequests: totalReq,
            totalActiveSeconds: totalSec,
            avgGenTps: avgTps,
            peakParallelSlots: peakParallel,
            avgParallelSlots: avgParallel,
            configuredSlots: maxConfigured,
            timePoints: timePoints,
            parallelPoints: parallelPoints,
            concurrencySlices: concurrencySlices,
            clientSummaries: clientSummaries,
            modelSummaries: modelSummaries
        )
    }

    // MARK: - Ollama Log Backfill

    private func parseOllamaLogBackfill(
        since cutoff: Date,
        excludingHours: Set<TimeInterval>
    ) -> ([UsageBucket], [ConcurrencyBucket]) {
        guard let path = logPaths.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let handle = FileHandle(forReadingAtPath: path) else {
            return ([], [])
        }
        defer { try? handle.close() }

        let fileSize = handle.seekToEndOfFile()
        let maxRead: UInt64 = 4 * 1024 * 1024
        if fileSize > maxRead {
            handle.seek(toFileOffset: fileSize - maxRead)
        } else {
            handle.seek(toFileOffset: 0)
        }

        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return ([], []) }

        let ginFormatter = DateFormatter()
        ginFormatter.locale = Locale(identifier: "en_US_POSIX")
        ginFormatter.dateFormat = "yyyy/MM/dd - HH:mm:ss"

        var currentTimestamp: Date?
        var resultMap: [String: UsageBucket] = [:]
        var slotIdsBy5Min: [TimeInterval: Set<Int>] = [:]
        var activeSecBy5Min: [TimeInterval: Double] = [:]

        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("[GIN] ") {
                let afterPrefix = line.dropFirst(6)
                if let pipeIdx = afterPrefix.firstIndex(of: "|") {
                    let dateStr = afterPrefix[..<pipeIdx].trimmingCharacters(in: .whitespaces)
                    if let parsed = ginFormatter.date(from: dateStr) {
                        currentTimestamp = parsed
                    }
                }
                continue
            }

            guard line.contains("slot print_timing:"),
                  let ts = currentTimestamp,
                  ts >= cutoff else {
                continue
            }

            let hourEpoch = floorInterval(ts, seconds: 3600).timeIntervalSince1970
            if excludingHours.contains(hourEpoch) { continue }

            let bucket5m = floorInterval(ts, seconds: 300).timeIntervalSince1970
            if let slotId = extractSlotId(in: line) {
                slotIdsBy5Min[bucket5m, default: []].insert(slotId)
            }

            let key = "\(Int64(bucket5m))|Ollama Log (Prior)|Local Model"
            var b = resultMap[key] ?? UsageBucket(
                hourEpoch: bucket5m,
                client: "Ollama Log (Prior)",
                model: "Local Model",
                genTokens: 0,
                promptTokens: 0,
                activeSeconds: 0,
                requestCount: 0,
                tpsSum: 0,
                tpsSamples: 0
            )

            if line.contains("prompt eval time ="),
               let tokens = extractTokensBeforeKeyword(in: line),
               let ms = extractMsBeforeSlash(in: line) {
                b.promptTokens += tokens
                b.activeSeconds += ms / 1000.0
                activeSecBy5Min[bucket5m, default: 0] += ms / 1000.0
                resultMap[key] = b
            } else if line.contains("eval time ="),
                      let tokens = extractTokensBeforeKeyword(in: line),
                      let ms = extractMsBeforeSlash(in: line) {
                b.genTokens += tokens
                b.activeSeconds += ms / 1000.0
                b.requestCount += 1
                activeSecBy5Min[bucket5m, default: 0] += ms / 1000.0
                if ms > 0 {
                    b.tpsSum += Double(tokens) / (ms / 1000.0)
                    b.tpsSamples += 1
                }
                resultMap[key] = b
            }
        }

        let concurrency = slotIdsBy5Min.map { (epoch, slotIds) -> ConcurrencyBucket in
            let parallelCount = max(1, slotIds.count)
            return ConcurrencyBucket(
                bucketEpoch: epoch,
                slotCounts: [parallelCount: 1],
                maxParallel: parallelCount,
                configuredSlots: parallelCount,
                activeSeconds: activeSecBy5Min[epoch] ?? 0
            )
        }

        return (Array(resultMap.values), concurrency)
    }

    private func extractSlotId(in line: String) -> Int? {
        guard let range = line.range(of: "id") else { return nil }
        let suffix = line[range.upperBound...].drop(while: { $0 == " " })
        let digits = suffix.prefix(while: { $0.isNumber })
        return Int(digits)
    }

    private func extractTokensBeforeKeyword(in line: String) -> Int? {
        guard let slashRange = line.range(of: "/"),
              let tokRange = line.range(of: "tokens", range: slashRange.upperBound..<line.endIndex) else {
            return nil
        }
        let numStr = line[slashRange.upperBound..<tokRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return Int(numStr)
    }

    private func extractMsBeforeSlash(in line: String) -> Double? {
        guard let eqRange = line.range(of: "="),
              let msRange = line.range(of: "ms", range: eqRange.upperBound..<line.endIndex) else {
            return nil
        }
        let numStr = line[eqRange.upperBound..<msRange.lowerBound].trimmingCharacters(in: .whitespaces)
        return Double(numStr)
    }

    // MARK: - Persistence & Helpers

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        if let payload = try? JSONDecoder().decode(UsageHistoryPayload.self, from: data) {
            for b in payload.buckets {
                buckets["\(Int64(b.hourEpoch))|\(b.client)|\(b.model)"] = b
            }
            for cb in payload.concurrency {
                concurrencyBuckets[cb.bucketEpoch] = cb
            }
        } else if let legacy = try? JSONDecoder().decode([UsageBucket].self, from: data) {
            for b in legacy {
                buckets["\(Int64(b.hourEpoch))|\(b.client)|\(b.model)"] = b
            }
        }
        pruneOldBucketsLocked(now: Date())
    }

    private func saveToDiskLocked() {
        let payload = UsageHistoryPayload(
            buckets: Array(buckets.values),
            concurrency: Array(concurrencyBuckets.values)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    private func pruneOldBucketsLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-31 * 24 * 3600).timeIntervalSince1970
        buckets = buckets.filter { $0.value.hourEpoch >= cutoff }
        concurrencyBuckets = concurrencyBuckets.filter { $0.key >= cutoff }
    }

    private func floorInterval(_ date: Date, seconds: TimeInterval) -> Date {
        let epoch = date.timeIntervalSince1970
        let floored = floor(epoch / seconds) * seconds
        return Date(timeIntervalSince1970: floored)
    }

    private func splitInt(_ total: Int, parts: Int, index: Int) -> Int {
        guard parts > 0 else { return total }
        let base = total / parts
        let rem = total % parts
        return base + (index < rem ? 1 : 0)
    }
}
