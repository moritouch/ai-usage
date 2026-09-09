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

    static func collect(force: Bool = false) -> AgentUsage {
        // 公式クライアントに直接聞けるならそれが常に最新。ログは使った分しか増えない。
        let live = CodexAppServer.observations(force: force)
        let hasLogs = FileManager.default.fileExists(atPath: sessionsRoot.path)
        guard live != nil || hasLogs || CodexAppServer.isAvailable else {
            return AgentUsage(id: "codex", name: "Codex", plan: nil, windows: [],
                              observedAt: nil, source: logSource,
                              status: .notInstalled, note: nil)
        }

        let source = live == nil ? logSource : liveSource
        let observations = live ?? latestObservations()
        guard let hit = selectBucket(from: observations) else {
            return AgentUsage(
                id: "codex", name: "Codex",
                plan: observations.first.flatMap { PlanLabel.normalize($0.limits.plan_type) },
                windows: [], observedAt: nil, source: source,
                status: .unavailable,
                note: hasOnlyModelBuckets(observations)
                    ? "Only model-specific Codex limits were found; run Codex on your plan's default model, then check again"
                    : "Run Codex once to populate its session log"
            )
        }

        var windows = usableWindows(of: hit.limits)
        // モデル別枠も一覧には出す。ただし代表値には使わない（補助枠）。
        for other in observations where !other.isPlanBucket {
            windows.append(contentsOf: usableWindows(of: other.limits, supplementary: true))
        }
        let isStale = Date().timeIntervalSince(hit.observedAt) > 6 * 3_600

        return AgentUsage(
            id: "codex",
            name: "Codex",
            plan: PlanLabel.normalize(hit.limits.plan_type),
            windows: windows,
            observedAt: hit.observedAt,
            source: source,
            status: windows.isEmpty ? .unavailable : (isStale ? .stale : .ok),
            note: nil
        )
    }

    /// 取得元。どちらから読めたかで案内が変わるので、表示にも残す。
    static let liveSource = "Codex CLI"
    static let logSource = "session log"

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
        /// Codexはプラン枠とモデル別枠を同じログへ別レコードとして書く。
        /// 例: プラン枠は "codex"、GPT-5.3-Codex-Sparkは "codex_bengalfox"。
        let limit_id: String?
        let limit_name: String?
    }

    /// 1バケット分の最新観測。
    struct Observation {
        let limits: RateLimits
        let observedAt: Date

        var bucketKey: String { limits.limit_id ?? "" }
        /// プラン全体の枠。モデル別枠と取り違えると、使っていないモデルの0%を出してしまう。
        var isPlanBucket: Bool {
            guard let id = limits.limit_id else { return true }
            return id == planLimitID
        }
    }

    static let planLimitID = "codex"

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

    static func usableWindows(
        of limits: RateLimits, supplementary: Bool = false
    ) -> [UsageWindow] {
        let prefix = supplementary ? (limits.limit_id ?? "model") + "-" : ""
        let name = supplementary ? shortBucketName(of: limits) : nil
        var windows: [UsageWindow] = []
        for (raw, fallbackID) in [(limits.primary, "primary"), (limits.secondary, "secondary")] {
            guard let raw, var window = window(from: raw, fallbackID: fallbackID) else { continue }
            if supplementary {
                window.id = prefix + window.id
                window.isSupplementary = true
                if let name { window.label = "\(name) \(window.label)" }
            }
            windows.append(window)
        }
        return windows
    }

    /// "GPT-5.3-Codex-Spark" のような表示名は長すぎるので末尾だけ使う。
    /// 名前が無い版では `codex_bengalfox` のような内部idから接頭辞を落として使う。
    static func shortBucketName(of limits: RateLimits) -> String? {
        if let name = limits.limit_name, !name.isEmpty {
            return name.split(separator: "-").last.map(String.init) ?? name
        }
        guard let id = limits.limit_id, !id.isEmpty else { return nil }
        return id.hasPrefix(planLimitID + "_")
            ? String(id.dropFirst(planLimitID.count + 1))
            : id
    }

    /// 表示するバケットを決める。プラン枠だけを採り、モデル別枠は採らない。
    ///
    /// 「最後に書かれた1件」を採ると、直前に使ったモデル次第でプラン枠とモデル別枠が
    /// 入れ替わる。モデル別枠は使っていなければ0%のままなので、代わりに出すと
    /// 「余裕がある」と誤読させる。プラン枠が無いときは数字を出さず、その旨を伝える。
    /// `limit_id`が無い旧形式のCodexもプラン枠として扱う。
    static func selectBucket(from observations: [Observation]) -> Observation? {
        observations
            .filter { $0.isPlanBucket && !usableWindows(of: $0.limits).isEmpty }
            .max { $0.observedAt < $1.observedAt }
    }

    /// プラン枠は無いがモデル別枠だけはある状態。「Codexを一度実行して」では的外れになる。
    static func hasOnlyModelBuckets(_ observations: [Observation]) -> Bool {
        !observations.isEmpty && observations.allSatisfy { !$0.isPlanBucket }
    }

    // MARK: - ログ走査

    /// バケットごとに最新の観測を1件ずつ集める。
    private static func latestObservations() -> [Observation] {
        var latest: [String: Observation] = [:]
        for file in recentSessionFiles() {
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
            for hit in scanTail(of: file) {
                guard let observedAt = hit.observedAt
                        ?? modified.flatMap(plausibleObservationDate)
                else { continue }
                let observation = Observation(limits: hit.limits, observedAt: observedAt)
                let key = observation.bucketKey
                if let existing = latest[key], existing.observedAt >= observedAt { continue }
                latest[key] = observation
            }
        }
        return Array(latest.values)
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

    /// ファイル末尾を後ろから読み、`limit_id` ごとに最新の rate_limits を1件ずつ取り出す。
    /// 末尾1件だけを返すと、直前に使ったモデルのバケットに引きずられる。
    static func scanTail(of url: URL) -> [(limits: RateLimits, observedAt: Date?)] {
        guard let data = readTail(of: url, maximumBytes: tailBytes) else { return [] }

        var seen = Set<String>()
        var hits: [(limits: RateLimits, observedAt: Date?)] = []
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

            // timestampが読めない行は捨てて更に遡るので、採用が確定してから既読にする。
            guard !seen.contains(limits.limit_id ?? "") else { continue }

            var observedAt: Date?
            if let rawTimestamp = root["timestamp"] {
                guard let timestamp = rawTimestamp as? String,
                      let parsed = parseTimestamp(timestamp)
                else { continue }
                observedAt = parsed
            }
            seen.insert(limits.limit_id ?? "")
            hits.append((limits, observedAt))
        }
        return hits
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
