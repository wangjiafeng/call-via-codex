import Foundation

struct QuotaWindow: Sendable {
    let title: String
    let remainingPercent: Double
    let resetDate: Date?
}

struct CodexQuota: Sendable {
    let windows: [QuotaWindow]
    let error: String?
}

enum CodexUsageReader {
    static func read(completion: @escaping @MainActor @Sendable (CodexQuota) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let path = executable("codex")
            guard let path else {
                Task { @MainActor in completion(CodexQuota(windows: [], error: "未找到 codex 命令")) }
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["app-server", "--listen", "stdio://"]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                    if process.isRunning { process.terminate() }
                }
                let initialize: [String: Any] = ["id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "call-via-codex", "title": "Call via Codex", "version": "1.0.0"],
                    "capabilities": ["experimentalApi": true]
                ]]
                let initialized: [String: Any] = ["method": "initialized", "params": [:]]
                let request: [String: Any] = ["id": 2, "method": "account/rateLimits/read", "params": [:]]
                // app-server requires a completed initialize handshake before it
                // will dispatch subsequent requests. Sending all three messages
                // at once can leave the rate-limit request unanswered.
                try write(initialize, to: input.fileHandleForWriting)
                guard awaitResponse(id: 1, from: output.fileHandleForReading) else {
                    process.terminate()
                    Task { @MainActor in completion(CodexQuota(windows: [], error: "Codex 未完成额度读取初始化")) }
                    return
                }
                try write(initialized, to: input.fileHandleForWriting)
                try write(request, to: input.fileHandleForWriting)
                guard let responseData = readResponse(id: 2, from: output.fileHandleForReading) else {
                    try? input.fileHandleForWriting.close()
                    process.terminate()
                    Task { @MainActor in completion(CodexQuota(windows: [], error: "Codex 未返回额度数据")) }
                    return
                }
                try? input.fileHandleForWriting.close()
                process.waitUntilExit()
                let quota = parse(responseData)
                Task { @MainActor in completion(quota) }
            } catch {
                process.terminate()
                Task { @MainActor in completion(CodexQuota(windows: [], error: "无法读取 Codex 额度")) }
            }
        }
    }

    private static func write(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        handle.write(data)
    }

    private static func awaitResponse(id: Int, from handle: FileHandle) -> Bool {
        readResponse(id: id, from: handle) != nil
    }

    private static func readResponse(id: Int, from handle: FileHandle) -> Data? {
        var line = Data()
        var collected = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            guard !byte.isEmpty else { return nil }
            if byte[0] == 0x0A {
                collected.append(line)
                collected.append(0x0A)
                if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   (json["id"] as? Int) == id { return json["error"] == nil ? collected : nil }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte[0])
            }
        }
    }

    private static func executable(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let paths = env.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in paths {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func parse(_ data: Data) -> CodexQuota {
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (json["id"] as? Int) == 2,
                  let result = json["result"] as? [String: Any] else { continue }
            var buckets: [[String: Any]] = []
            if let map = result["rateLimitsByLimitId"] as? [String: [String: Any]] {
                if let codex = map["codex"] { buckets = [codex] }
                else { buckets = Array(map.values) }
            }
            if buckets.isEmpty, let one = result["rateLimits"] as? [String: Any] { buckets = [one] }
            let windows = buckets.flatMap { bucket -> [QuotaWindow] in
                ["primary", "secondary"].compactMap { slot in
                    guard let item = bucket[slot] as? [String: Any],
                          let used = number(item["usedPercent"]),
                          let duration = number(item["windowDurationMins"]) else { return nil }
                    let label = duration <= 360 ? "五小时" : "本周"
                    let reset = number(item["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
                    return QuotaWindow(title: label, remainingPercent: max(0, min(100, 100 - used)), resetDate: reset)
                }
            }
            let deduplicated = Dictionary(grouping: windows, by: \.title).compactMap { $0.value.first }.sorted { $0.title == "五小时" && $1.title != "五小时" }
            return CodexQuota(windows: deduplicated, error: deduplicated.isEmpty ? "Codex 未返回可识别的额度窗口" : nil)
        }
        return CodexQuota(windows: [], error: "额度暂不可用：请确认 Codex 已登录")
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}
