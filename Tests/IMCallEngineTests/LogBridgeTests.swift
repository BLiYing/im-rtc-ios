import XCTest

@testable import IMCallEngine

final class LogBridgeTests: XCTestCase {
    override func tearDown() {
        IMRTCLogBridge.uninstall()
        IMRTCLog.setLevel(.info)
        super.tearDown()
    }

    /// ObjC 桥收到日志：级别是 rawValue，字段按键排序拼在正文后；低于最低级别的不来。
    func testHandlerReceivesLevelAndFields() {
        var got: [(Int, String)] = []
        IMRTCLogBridge.install(minLevel: IMRTCLogLevel.warn.rawValue) { got.append(($0, $1)) }
        IMRTCLog.info("不该收到")
        IMRTCLog.warn("掉线", ["b": "2", "a": "1"])
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.0, IMRTCLogLevel.warn.rawValue)
        XCTAssertEqual(got.first?.1, "掉线 a=1 b=2")
    }
}
