import Foundation

/// Codex のプラン枠を、公式クライアント自身に聞いて読む。
///
/// セッションログ（rollout-*.jsonl）はターミナルの `codex` を使ったときしか増えない。
/// 公式アプリだけを使っていると古い値で止まるため、`codex app-server` の JSON-RPC に
/// 直接尋ねる。返るのは `/status` と同じ値で、推論は走らず、`~/.codex` へは何も書かれない。
enum CodexAppServer {
    /// 起動から応答までの上限。手元では1秒ほどで返る。
    private static let responseTimeout: TimeInterval = 8

    /// 応答を待つ間に溜め込む上限。想定外に喋り続けても記憶を食い潰さない。
    private static let bufferLimit = 1 << 20

    private static let rateLimitsRequestID = 2

    /// 相手が先に終了した直後の書き込みでプロセスごと落とされないようにする。
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// 使える実行体を順に試す。1つ目が古くて `account/rateLimits/read` を知らなくても、
    /// もう一方で拾えることがある。
    static func executableCandidates() -> [URL] {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let located = CLILocator.locate("codex") { candidates.append(located) }

        // 公式アプリは自前の codex を同梱している。CLIを入れていない人でもここにある。
        for path in [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/ChatGPT.app/Contents/Resources/codex",
        ] where manager.isExecutableFile(atPath: path) {
            candidates.append(URL(fileURLWithPath: path))
        }
        return candidates
    }

    static var isAvailable: Bool { !executableCandidates().isEmpty }

    /// 本体は毎分更新するが、週や5時間の枠にその粒度は要らない。
    /// 起動と外部への問い合わせを毎分繰り返さないよう、この間隔までは前回の答えを使う。
    private static let minimumInterval: TimeInterval = 5 * 60

    private static let cache = Cache()

    /// - Parameter force: 「再確認」で押されたときは間隔を待たずに聞き直す。
    static func observations(force: Bool = false,
                             now: Date = Date()) -> [CodexCollector.Observation]? {
        // 失敗も間隔に含める。ログイン前などで毎分起動し続けても得るものがない。
        if !force, let recent = cache.recentAttempt(after: now - minimumInterval) {
            return recent?.observations
        }
        for executable in executableCandidates() {
            if let buckets = rateLimits(using: executable), !buckets.isEmpty {
                let answer = Answer(buckets: buckets, observedAt: now)
                cache.store(answer, at: now)
                return answer.observations
            }
        }
        cache.store(nil, at: now)
        return nil
    }

    private struct Answer {
        let buckets: [CodexCollector.RateLimits]
        let observedAt: Date

        var observations: [CodexCollector.Observation] {
            buckets.map { .init(limits: $0, observedAt: observedAt) }
        }
    }

    /// 収集は本体とは別のタスクで走るので、錠を掛けて持つ。
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var attemptedAt: Date?
        private var answer: Answer?

        /// 直近に試していれば、その結果（成功なら答え、失敗なら nil）を二重の Optional で返す。
        /// 外側の nil は「まだ試していないので聞きに行くべき」。
        func recentAttempt(after cutoff: Date) -> Answer?? {
            lock.lock()
            defer { lock.unlock() }
            guard let attemptedAt, attemptedAt > cutoff else { return nil }
            return .some(answer)
        }

        func store(_ answer: Answer?, at date: Date) {
            lock.lock()
            self.answer = answer
            attemptedAt = date
            lock.unlock()
        }
    }

    // MARK: - JSON-RPC

    private static func rateLimits(using executable: URL) -> [CodexCollector.RateLimits]? {
        _ = ignoreBrokenPipe

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // 進捗や警告は読み手がいないと詰まるので捨てる。
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // 応答が来ない相手を待ち続けない。terminate で読み側にEOFが届く。
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + responseTimeout, execute: watchdog)
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        // initialize を通さないと他のメソッドは "Not initialized" で弾かれる。
        let handshake = """
        {"jsonrpc":"2.0","id":1,"method":"initialize",\
        "params":{"clientInfo":{"name":"AI Usage","version":"\(clientVersion)"}}}
        {"jsonrpc":"2.0","id":\(rateLimitsRequestID),"method":"account/rateLimits/read"}

        """
        guard let request = handshake.data(using: .utf8),
              (try? input.fileHandleForWriting.write(contentsOf: request)) != nil
        else { return nil }

        return readResponse(from: output.fileHandleForReading)
    }

    /// 行区切りJSON。要求への応答の合間に通知も流れてくるので、idで選ぶ。
    private static func readResponse(from handle: FileHandle) -> [CodexCollector.RateLimits]? {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let buckets = buckets(fromResponseLine: line) else { continue }
                return buckets
            }
            if buffer.count > bufferLimit { return nil }
        }
    }

    /// 1行を読んで、求めた応答ならバケットを返す。通知や他の応答なら nil。
    /// 応答がエラーだったときは空配列。呼び出し側はそこで諦める。
    static func buckets(fromResponseLine line: Data) -> [CodexCollector.RateLimits]? {
        guard let message = try? JSONDecoder().decode(Response.self, from: line),
              message.id == rateLimitsRequestID
        else { return nil }
        return message.result?.buckets ?? []
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - 応答の形

    /// ログはスネークケース、こちらはキャメルケースで同じ中身を返す。
    /// 表示側を二重に持ちたくないので、読み取った時点でログ側の型に寄せる。
    struct Response: Decodable {
        struct Result: Decodable {
            let rateLimits: Bucket?
            let rateLimitsByLimitId: [String: Bucket]?

            /// バケット一覧が来ないぶん古い版でも、代表の1件だけは拾えるようにする。
            var buckets: [CodexCollector.RateLimits] {
                let all = rateLimitsByLimitId.map { Array($0.values) } ?? rateLimits.map { [$0] } ?? []
                return all.map(\.asRateLimits)
            }
        }

        struct Bucket: Decodable {
            struct Window: Decodable {
                let usedPercent: Double?
                let windowDurationMins: Int?
                let resetsAt: Double?

                var asWindow: CodexCollector.RateLimits.Window {
                    .init(used_percent: usedPercent,
                          window_minutes: windowDurationMins,
                          resets_at: resetsAt)
                }
            }

            let limitId: String?
            let limitName: String?
            let planType: String?
            let primary: Window?
            let secondary: Window?

            var asRateLimits: CodexCollector.RateLimits {
                .init(primary: primary?.asWindow,
                      secondary: secondary?.asWindow,
                      plan_type: planType,
                      limit_id: limitId,
                      limit_name: limitName)
            }
        }

        let id: Int?
        let result: Result?
    }
}
