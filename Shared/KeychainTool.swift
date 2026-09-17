import Foundation
import Security

/// `/usr/bin/security` を介して汎用パスワード項目を読み書きする。
///
/// Claude Code自身がこの経路で読み書きするため、項目のアクセス設定には常に
/// `/usr/bin/security`（パーティション `apple-tool:`）が残る。Security frameworkで
/// 直接触ると、書き込みのたびにパーティションが書き手自身へ置き換わり、締め出された
/// 側はアクセスのたびにログインパスワードを求められる。同じ道具を使えば、どちらが
/// 書いても互いを締め出さない。
enum KeychainTool {
    static let executable = URL(fileURLWithPath: "/usr/bin/security")

    /// 許可ダイアログが出た場合はその応答までここで待つ。無応答なら拒否として扱う。
    static let timeout: TimeInterval = 60

    /// `security -i` の1行は約4KBまで。超えた行は途中で切られ、前半だけが実行されて
    /// 切り詰めた値が保存される（実測）。境界に寄せず、余裕を取って抑える。
    static let interactiveLineLimit = 4_000

    struct Invocation: Equatable {
        let arguments: [String]
        let standardInput: Data?
    }

    static func readInvocation(service: String, account: String) -> Invocation {
        Invocation(
            arguments: ["find-generic-password", "-a", account, "-s", service, "-w"],
            standardInput: nil
        )
    }

    /// 値は標準入力の対話モードで渡し、他プロセスから見える引数に載せない。
    ///
    /// 1行に収まらない場合だけ引数で渡す（Claude Codeも同じ）。引数が見えるのは
    /// 同じ利用者のプロセスに限られ、それらはこの道具で既に値を読めるため、
    /// 見える範囲は広がらない。
    static func writeInvocation(_ data: Data, service: String, account: String) -> Invocation {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        if isSafeInteractiveToken(account), isSafeInteractiveToken(service) {
            let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\""
            if line.utf8.count <= interactiveLineLimit {
                return Invocation(arguments: ["-i"], standardInput: Data((line + "\n").utf8))
            }
        }
        return Invocation(
            arguments: ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex],
            standardInput: nil
        )
    }

    /// 対話モードの行は二重引用符で区切るので、区切りを崩す文字は通さない。
    private static func isSafeInteractiveToken(_ text: String) -> Bool {
        !text.isEmpty && !text.contains { "\"\\\n\r".contains($0) }
    }

    /// 読み取り。成功時は項目の値を返す。
    static func read(service: String, account: String) -> (OSStatus, Data?) {
        let (status, output) = run(readInvocation(service: service, account: account))
        guard status == errSecSuccess else { return (status, nil) }
        return (status, decodePasswordOutput(output))
    }

    static func write(_ data: Data, service: String, account: String) -> OSStatus {
        run(writeInvocation(data, service: service, account: account)).status
    }

    /// `-w` の出力。ASCII以外を含む値は16進で出てくる（実測）。
    static func decodePasswordOutput(_ output: Data) -> Data {
        var trimmed = output
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        if (try? JSONSerialization.jsonObject(with: trimmed)) != nil { return trimmed }
        if let decoded = decodeHex(trimmed) { return decoded }
        return trimmed
    }

    private static func decodeHex(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count / 2)
        var high: UInt8?
        for character in data {
            let nibble: UInt8
            switch character {
            case 0x30...0x39: nibble = character - 0x30
            case 0x41...0x46: nibble = character - 0x41 + 10
            case 0x61...0x66: nibble = character - 0x61 + 10
            default: return nil
            }
            if let upper = high {
                bytes.append(upper << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return Data(bytes)
    }

    /// 終了コードはOSStatusの下位8bit（項目なしの -25300 は 44 になる）。
    static func status(forExitCode code: Int32) -> OSStatus {
        guard code != 0 else { return errSecSuccess }
        let known: [OSStatus] = [
            errSecItemNotFound, errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled,
        ]
        return known.first { Int32(UInt32(bitPattern: $0) & 0xFF) == code } ?? errSecNotAvailable
    }

    /// 相手が先に終了した直後の書き込みで、アプリごと落とされないようにする。
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    private static func run(_ invocation: Invocation) -> (status: OSStatus, output: Data) {
        _ = ignoreBrokenPipe
        let process = Process()
        process.executableURL = executable
        process.arguments = invocation.arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let input = invocation.standardInput.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice

        do { try process.run() } catch { return (errSecNotAvailable, Data()) }

        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        if let input, let data = invocation.standardInput {
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // 応答の無いダイアログを閉じた場合も拒否と同じに扱い、自動では聞き直さない。
        if timedOut.isSet { return (errSecInteractionNotAllowed, Data()) }
        return (status(forExitCode: process.terminationStatus), data)
    }

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
