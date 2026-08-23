import Foundation

/// Codex の残量。
///
/// Codex はセッションログ（~/.codex/sessions/**/rollout-*.jsonl）に `rate_limits`
/// を自動で書き残す。フックの導入も API 呼び出しも不要で、最新のものを読むだけで良い。
enum CodexCollector {
    private static let sessionsRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    /// 各ファイルの末尾だけを見る。rate_limits は頻繁に書かれるので十分。
    private static let tailBytes = 2 * 1_024 * 1_024

    static func collect() -> AgentUsage {
        let installed = FileManager.default.fileExists(atPath: sessionsRoot.path)
        guard installed else {
            return AgentUsage(id: "codex", name: "Codex", plan: nil, windows: [],
                              observedAt: nil, source: "session log",
                              status: .notInstalled, note: nil)
        }

        guard let hit = latestRateLimits() else {
            return AgentUsage(id: "codex", name: "Codex", plan: nil, windows: [],
                              observedAt: nil, source: "session log",
                              status: .unavailable,
                              note: "Run Codex once to populate its session log")
        }

        var windows: [UsageWindow] = []
        if let primary = hit.limits.primary,
           let window = window(from: primary, fallbackID: "primary") {
            windows.append(window)
        }
        if let secondary = hit.limits.secondary,
           let window = window(from: secondary, fallbackID: "secondary") {
            windows.append(window)
        }

        let isStale = Date().timeIntervalSince(hit.observedAt) > 6 * 3_600

        return AgentUsage(
            id: "codex",
            name: "Codex",
            plan: PlanLabel.normalize(hit.limits.plan_type),
            windows: windows,
            observedAt: hit.observedAt,
            source: "session log",
            status: windows.isEmpty ? .unavailable : (isStale ? .stale : .ok),
            note: nil
        )
    }

    // MARK: - JSON 形状

    struct RateLimits: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let window_minutes: Int?
            let resets_at: Double?
        }
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }

    private static func window(from raw: RateLimits.Window, fallbackID: String) -> UsageWindow? {
        guard let used = raw.used_percent,
              used.isFinite,
              (0...100).contains(used)
        else { return nil }

        let minutes = raw.window_minutes ?? 0
        guard minutes >= 0, minutes <= 10 * 365 * 24 * 60 else { return nil }
        let label: String
        switch minutes {
        case 0: label = fallbackID == "primary" ? "Usage" : "Secondary"
        case ..<60: label = "\(minutes)m"
        case ..<1_440: label = "\(minutes / 60)h"
        case 10_080: label = "7d"
        case 43_200: label = "30d"
        default: label = "\(minutes / 1_440)d"
        }
        return UsageWindow(
            id: minutes > 0 ? "\(fallbackID)-w\(minutes)" : fallbackID,
            label: label,
            usedPercent: used,
            resetsAt: validEpoch(raw.resets_at),
            windowSeconds: minutes > 0 ? TimeInterval(minutes) * 60 : nil
        )
    }

    // MARK: - ログ走査

    private static func latestRateLimits() -> (limits: RateLimits, observedAt: Date)? {
        var latest: (limits: RateLimits, observedAt: Date)?
        for file in recentSessionFiles() {
            guard let hit = scanTail(of: file) else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
            guard let observedAt = hit.observedAt
                    ?? modified.flatMap(plausibleObservationDate)
            else { continue }
            if latest == nil || observedAt > latest!.observedAt {
                latest = (hit.limits, observedAt)
            }
        }
        return latest
    }

    /// 更新が新しい順に最大 20 件。
    private static func recentSessionFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: sessionsRoot, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [(URL, Date)] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            found.append((url, values.contentModificationDate ?? .distantPast))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(20).map(\.0)
    }

    /// ファイル末尾を後ろから読み、最後の rate_limits を取り出す。
    static func scanTail(of url: URL) -> (limits: RateLimits, observedAt: Date?)? {
        guard let data = readTail(of: url, maximumBytes: tailBytes) else { return nil }

        for rawLine in data.split(separator: 0x0A).reversed() {
            guard let line = String(data: Data(rawLine), encoding: .utf8) else { continue }
            guard line.contains("\"rate_limits\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  root["type"] as? String == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = findRateLimits(in: payload)
            else { continue }

            var observedAt: Date?
            if let rawTimestamp = root["timestamp"] {
                guard let timestamp = rawTimestamp as? String,
                      let parsed = parseTimestamp(timestamp)
                else { continue }
                observedAt = parsed
            }
            return (limits, observedAt)
        }
        return nil
    }

    /// オフセットが UTF-8 の途中でも、先頭の不完全な行を捨てて残りを行単位で解析する。
    private static func readTail(of url: URL, maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let count = min(UInt64(maximumBytes), size)
        let offset = size - count
        do {
            try handle.seek(toOffset: offset)
            guard var data = try handle.read(upToCount: Int(count)) else { return nil }
            if offset > 0 {
                guard let newline = data.firstIndex(of: 0x0A) else { return nil }
                let start = data.index(after: newline)
                data = start < data.endIndex ? Data(data[start...]) : Data()
            }
            return data
        } catch {
            return nil
        }
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text))
            .flatMap(plausibleObservationDate)
    }

    private static func plausibleObservationDate(_ date: Date) -> Date? {
        let distance = date.timeIntervalSinceNow
        guard distance.isFinite,
              distance >= -10 * 365 * 86_400,
              distance <= 5 * 60
        else { return nil }
        return date
    }

    private static func validEpoch(_ value: Double?) -> Date? {
        guard let value, value.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: value)
        let distance = date.timeIntervalSinceNow
        guard distance.isFinite,
              distance >= -370 * 86_400,
              distance <= 10 * 365 * 86_400
        else { return nil }
        return date
    }

    /// rate_limits はイベント種別によって入れ子の深さが変わるので再帰で探す。
    static func findRateLimits(in object: Any) -> RateLimits? {
        var remainingNodes = 2_048
        return findRateLimits(in: object, depth: 0, remainingNodes: &remainingNodes)
    }

    private static func findRateLimits(
        in object: Any,
        depth: Int,
        remainingNodes: inout Int
    ) -> RateLimits? {
        guard depth <= 32, remainingNodes > 0 else { return nil }
        remainingNodes -= 1

        guard let dict = object as? [String: Any] else {
            guard let array = object as? [Any] else { return nil }
            for value in array {
                if let limits = findRateLimits(
                    in: value, depth: depth + 1, remainingNodes: &remainingNodes
                ) { return limits }
            }
            return nil
        }
        if let raw = dict["rate_limits"] as? [String: Any],
           JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let limits = try? JSONDecoder().decode(RateLimits.self, from: data),
           hasUsableWindow(in: limits) {
            return limits
        }
        for value in dict.values {
            if let limits = findRateLimits(
                in: value, depth: depth + 1, remainingNodes: &remainingNodes
            ) { return limits }
        }
        return nil
    }

    private static func hasUsableWindow(in limits: RateLimits) -> Bool {
        if let primary = limits.primary,
           window(from: primary, fallbackID: "primary") != nil {
            return true
        }
        if let secondary = limits.secondary,
           window(from: secondary, fallbackID: "secondary") != nil {
            return true
        }
        return false
    }
}
