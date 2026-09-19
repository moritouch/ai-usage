import Foundation
import XCTest

final class StaleWidgetExtensionTests: XCTestCase {
    /// 取りこぼすと旧版の拡張が残り、ウィジェットが仮表示のまま止まる。
    func testFindsARunningProcessByTheEndOfItsPath() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer { process.terminate() }

        XCTAssertTrue(
            StaleWidgetExtension.runningProcesses(whosePathEndsWith: "/bin/sleep")
                .contains(process.processIdentifier)
        )
        XCTAssertTrue(
            StaleWidgetExtension.runningProcesses(
                whosePathEndsWith: "/AIUsageWidget.appex/Contents/MacOS/NoSuchExecutable"
            ).isEmpty
        )
    }
}
