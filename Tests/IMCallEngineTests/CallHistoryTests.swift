import XCTest
@testable import IMCallEngine

final class CallHistoryTests: XCTestCase {

    func testRestBaseURLFromSignalingURL() {
        let cases: [(String, String)] = [
            ("ws://127.0.0.1:8787/v1/ws", "http://127.0.0.1:8787"),
            ("wss://rtc.example.com/v1/ws", "https://rtc.example.com"),
            ("wss://rtc.example.com/gw/v1/ws?x=1", "https://rtc.example.com/gw"),
            ("https://rtc.example.com/v1/ws", "https://rtc.example.com"),
        ]
        for (input, want) in cases {
            let got = IMCallEngine.restBaseURL(fromSignalingURL: URL(string: input)!)
            XCTAssertEqual(got?.absoluteString, want, input)
        }
        XCTAssertNil(IMCallEngine.restBaseURL(fromSignalingURL: URL(string: "ftp://h/v1/ws")!))
    }

    func testRequestCarriesBearerLimitAndCursor() throws {
        let url = URL(string: "ws://h:8787/v1/ws")!
        let first = try IMCallEngine.makeCallHistoryRequest(
            signalingURL: url, token: "tok", limit: 20, cursor: nil)
        XCTAssertEqual(first.url?.absoluteString, "http://h:8787/v1/calls?limit=20")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let next = try IMCallEngine.makeCallHistoryRequest(
            signalingURL: url, token: "tok", limit: 20, cursor: 1700000000000)
        XCTAssertEqual(next.url?.query, "limit=20&cursor=1700000000000")
    }

    private func body(count: Int, next: Int64?) -> Data {
        let calls = (0..<count).map {
            #"{"call_id":"c\#($0)","caller":"alice","media_type":"video","is_group":false,"reason":"hangup","duration_sec":12,"started_at_ms":\#(1000 - $0),"members":[{"uid":"bob","state":"joined"}]}"#
        }.joined(separator: ",")
        let cursor = next.map { #","next_cursor":\#($0)"# } ?? ""
        return Data(#"{"calls":[\#(calls)]\#(cursor)}"#.utf8)
    }

    func testFullPageHandsBackCursorShortPageIsEnd() throws {
        let full = try IMCallEngine.parseCallHistory(status: 200, body: body(count: 2, next: 999), limit: 2)
        XCTAssertEqual(full.records.count, 2)
        XCTAssertEqual(full.nextCursor, 999)
        XCTAssertEqual(full.records[0].callID, "c0")
        XCTAssertEqual(full.records[0].members, [IMCallHistoryMember(uid: "bob", state: "joined")])
        XCTAssertEqual(full.records[0].durationSec, 12)

        let short = try IMCallEngine.parseCallHistory(status: 200, body: body(count: 1, next: 999), limit: 2)
        XCTAssertNil(short.nextCursor, "不满一页就是最后一页，不能再给游标")
        let empty = try IMCallEngine.parseCallHistory(status: 200, body: Data(#"{"calls":[]}"#.utf8), limit: 2)
        XCTAssertTrue(empty.records.isEmpty)
        XCTAssertNil(empty.nextCursor)
    }

    func testMissingFieldsDecodeToZeroValues() throws {
        let page = try IMCallEngine.parseCallHistory(
            status: 200, body: Data(#"{"calls":[{"call_id":"c1"}]}"#.utf8), limit: 20)
        XCTAssertEqual(page.records[0].callID, "c1")
        XCTAssertEqual(page.records[0].reason, "")
        XCTAssertEqual(page.records[0].durationSec, 0)
        XCTAssertTrue(page.records[0].members.isEmpty)
    }

    func testStatusMapping() {
        XCTAssertThrowsError(try IMCallEngine.parseCallHistory(status: 401, body: Data(), limit: 20)) {
            XCTAssertEqual(($0 as? IMRTCError)?.code, .tokenInvalid)
        }
        XCTAssertThrowsError(try IMCallEngine.parseCallHistory(status: 500, body: Data(), limit: 20)) {
            XCTAssertEqual(($0 as? IMRTCError)?.code, .internalError)
        }
        XCTAssertThrowsError(try IMCallEngine.parseCallHistory(status: 200, body: Data("nope".utf8), limit: 20))
    }

    func testFetchBeforeLoginThrowsNotLoggedIn() async {
        let engine = IMCallEngine(url: URL(string: "ws://h/v1/ws")!, deviceID: "d1")
        do {
            _ = try await engine.fetchCallHistory()
            XCTFail("未登录本该抛错")
        } catch {
            XCTAssertEqual((error as? IMRTCError)?.code, .notLoggedIn)
        }
    }
}
