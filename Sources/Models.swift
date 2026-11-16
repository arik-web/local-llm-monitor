import Foundation

enum ComputerInfo {
    static let name: String = {
        if let localized = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localized.isEmpty {
            return localized
        }
        let host = ProcessInfo.processInfo.hostName
        if host.hasSuffix(".local") {
            return String(host.dropLast(6))
        }
        return host
    }()
}

struct LoadedModelInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let parameterSize: String
    let quantization: String
    let sizeVramBytes: Int64
    let contextLength: Int
    let runner: String

    var vramGBString: String {
        let gb = Double(sizeVramBytes) / 1_073_741_824.0
        return String(format: "%.1f GB", gb)
    }
}

enum SlotPhase: String, Equatable {
    case generating = "Generating"
    case promptEval = "Prompt Eval"
    case starting = "Starting"
    case idle = "Idle"
}

struct SlotOwner: Equatable, Hashable {
    let computer: String
    let program: String
    let detail: String?

    var displayLabel: String {
        if let detail, !detail.isEmpty {
            return "\(computer) · \(program) · \(detail)"
        }
        return "\(computer) · \(program)"
    }

    var reportClientKey: String {
        if let detail, !detail.isEmpty {
            return "\(program) — \(detail)"
        }
        return program
    }
}

struct SlotInfo: Identifiable, Equatable {
    let id: String
    let slotId: Int
    let port: Int
    let taskId: Int?
    let isProcessing: Bool
    let phase: SlotPhase
    let genTps: Double
    let promptTps: Double
    let nDecoded: Int
    let nPromptTokens: Int
    let nPromptProcessed: Int
    let nCtx: Int
    let owner: SlotOwner?
    let elapsedSeconds: Double

    var activeTps: Double {
        switch phase {
        case .generating:
            return genTps
        case .promptEval:
            return promptTps
        case .starting, .idle:
            return 0
        }
    }

    var promptProgress: Double {
        guard nPromptTokens > 0 else { return 0 }
        return min(1.0, Double(nPromptProcessed) / Double(nPromptTokens))
    }

    var contextUsageRatio: Double {
        guard nCtx > 0 else { return 0 }
        let used = nPromptProcessed + nDecoded
        return min(1.0, Double(used) / Double(nCtx))
    }
}

struct ClientSession: Identifiable, Equatable {
    let id: String
    let name: String
    let computer: String
    let isConnected: Bool
    let connectionCount: Int
    let pids: [Int32]
    let isKnownHarness: Bool
    let activeDetails: [String]
}

struct QueuedTask: Identifiable, Equatable {
    let id: String
    let position: Int
    let computer: String
    let program: String
    let model: String
    let path: String
    let waitSeconds: Double
}

struct MonitorSnapshot: Equatable {
    let timestamp: Date
    let ollamaOnline: Bool
    let models: [LoadedModelInfo]
    let slots: [SlotInfo]
    let clients: [ClientSession]
    let queuedTasks: [QueuedTask]

    var activeSlots: [SlotInfo] {
        slots.filter { $0.isProcessing }
    }

    var activeSessionCount: Int {
        activeSlots.count
    }

    var totalGenTps: Double {
        activeSlots.filter { $0.phase == .generating }.reduce(0) { $0 + $1.genTps }
    }

    var totalPromptTps: Double {
        activeSlots.filter { $0.phase == .promptEval }.reduce(0) { $0 + $1.promptTps }
    }

    var totalCombinedTps: Double {
        activeSlots.reduce(0) { $0 + $1.activeTps }
    }

    var connectedClientCount: Int {
        clients.filter { $0.isConnected }.count
    }

    static let empty = MonitorSnapshot(
        timestamp: Date(),
        ollamaOnline: false,
        models: [],
        slots: [],
        clients: [],
        queuedTasks: []
    )
}
