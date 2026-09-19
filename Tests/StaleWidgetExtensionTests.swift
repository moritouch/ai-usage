import Foundation
import XCTest

final class StaleWidgetExtensionTests: XCTestCase {
    /// 取りこぼすと旧版の拡張が残り、ウィジェットが仮表示のまま止まる。
    /// Sparkleの更新では旧版の実行ファイルが消えるので、ファイルが無くなっても見つかること。
    func testFindsARunningProcessByNameAfterItsExecutableIsGone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "AIUsageStale\(Int.random(in: 100...999))"
        let executable = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["10"]
        try process.run()
        defer { process.terminate() }
        try FileManager.default.removeItem(at: directory)

        XCTAssertTrue(
            StaleWidgetExtension.runningProcesses(named: name).contains(process.processIdentifier)
        )
        XCTAssertTrue(StaleWidgetExtension.runningProcesses(named: "NoSuchProcess").isEmpty)
    }
}
