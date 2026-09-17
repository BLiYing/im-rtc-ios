import XCTest
@testable import IMCallEngine

/// assertThrowsCode 断言一次 async 调用以某个 `IMRTCError` 码失败（2.0.0 起结果回给调用方）。
/// `forType` 给了就一起比。
func assertThrowsCode(_ code: IMErrorCode, forType: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("应当 throw \(code.name)(\(code.rawValue))，实际成功了", file: file, line: line)
    } catch let error as IMRTCError {
        XCTAssertEqual(error.code, code, "错误码（实际 \(error)）", file: file, line: line)
        if let forType { XCTAssertEqual(error.forType, forType, "forType", file: file, line: line) }
    } catch {
        XCTFail("应当 throw IMRTCError，实际 \(error)", file: file, line: line)
    }
}
