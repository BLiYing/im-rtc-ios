import XCTest
@testable import IMCallEngine

/// 一致性向量覆盖不到的、**Swift 这一端特有**的坑。
final class ProtocolTests: XCTestCase {
    /// `JSONSerialization` 把 `true` 与 `1` 都变成 `NSNumber`。
    ///
    /// `NSNumber(value: 1) is Bool` 是 **true**——用 `is Bool` 判类型的话，
    /// 「bool 不能写成 0/1」这条规则在 Swift 端等于不存在，而向量里那一条
    /// （bool_must_not_be_int）却会照样通过，因为它测的是最终结果不是判定方式。
    /// 所以这里单独钉一遍两个方向。
    func testBoolAndIntAreNotInterchangeable() throws {
        let json = try IMJSON.parse(#"{"flag": true, "count": 1}"#)
        let fields = json.objectValue

        XCTAssertEqual(fields?["flag"], .bool(true))
        XCTAssertEqual(fields?["count"], .int(1))
        // 反向也要成立：布尔取不出整数，整数取不出布尔。
        XCTAssertNil(fields?["flag"]?.intValue)
        XCTAssertNil(fields?["count"]?.boolValue)
    }

    /// 协议里没有 null——**任何位置**。
    func testNullIsRejectedAnywhere() {
        for raw in [#"{"a": null}"#, #"{"a": [1, null]}"#, #"{"a": {"b": null}}"#] {
            XCTAssertThrowsError(try IMJSON.parse(raw), raw) { error in
                XCTAssertEqual((error as? IMRTCError)?.code, .badEnvelope, raw)
            }
        }
    }

    /// 数字按**值**判而不是按字面量：`1e3` 是整数 1000，合法。
    ///
    /// 这条是写 TS 实现时抓到的 Go/TS 漂移，Swift 这边同一个口径。
    func testIntegerInExponentFormIsAccepted() throws {
        XCTAssertEqual(try IMJSON.parse(#"{"n": 1e3}"#).objectValue?["n"], .int(1000))
        XCTAssertThrowsError(try IMJSON.parse(#"{"n": 15e-1}"#))
    }

    /// 发送侧的默认值陷阱：`room.join` 的 auto_subscribe / publish_audio 默认是 **true**。
    ///
    /// 直接发一个空 data，线路上会变成 false，人进了房却收不到任何流。
    /// 三端都踩过这一条，所以每端都要有一条测试钉住它。
    func testJoinDefaultsAreNotZeroValues() throws {
        let defaults = FieldCodec.defaults(RoomFrames.join)
        XCTAssertEqual(defaults["auto_subscribe"], .bool(true))
        XCTAssertEqual(defaults["publish_audio"], .bool(true))
        XCTAssertEqual(defaults["publish_video"], .bool(false))
    }

    /// 每个上行请求帧都要能查到字段声明，`.ok` 也要有（纯 ack 自动派生空对象）。
    func testEveryRequestTypeIsRegistered() {
        for type in IMFrameRegistry.requestTypes {
            XCTAssertNotNil(IMFrameRegistry.fields(for: type), "\(type) 没有登记字段声明")
            XCTAssertNotNil(IMFrameRegistry.fields(for: IMEnvelope.okType(type)),
                            "\(type).ok 查不到——纯 ack 应当自动派生")
        }
    }

    /// 会议层留位帧要报 `not_implemented`，而不是「未知帧」。
    ///
    /// 两者对客户端的含义完全不同：一个是「将来会有」，一个是「压根没有」。
    func testReservedTypesReportNotImplemented() throws {
        let raw = #"{"type":"room.kick","req_id":"c-1","ts":1,"data":{}}"#
        let envelope = try IMEnvelope.decode(raw)
        XCTAssertThrowsError(try envelope.decodedData()) { error in
            XCTAssertEqual((error as? IMRTCError)?.code, .notImplemented)
        }
    }

    /// 信封编解码往返。
    func testEnvelopeRoundTrip() throws {
        let envelope = IMEnvelope(type: IMFrameType.callHangup, reqID: "c-9", timestampMS: 1_756_876_800_123,
                                  data: ["call_id": .string("call-1")])
        let decoded = try IMEnvelope.decode(try envelope.encode())
        XCTAssertEqual(decoded, envelope)
    }

    /// 事件的 req_id 是**空串**，不是缺席——缺了就是非法信封。
    func testMissingReqIDIsRejectedButEmptyIsFine() throws {
        let event = #"{"type":"call.ended","req_id":"","ts":1,"data":{"call_id":"c1","reason":"hangup","duration_sec":5,"ended_by":"alice"}}"#
        XCTAssertTrue(try IMEnvelope.decode(event).isEvent)

        let missing = #"{"type":"sys.ping","ts":1,"data":{}}"#
        XCTAssertThrowsError(try IMEnvelope.decode(missing)) { error in
            XCTAssertEqual((error as? IMRTCError)?.code, .badEnvelope)
        }
    }

    /// 枚举收到集合外的值折成兜底值，**不崩也不透传**。
    func testUnknownEnumFallsBack() throws {
        let raw = #"{"type":"room.update_layer","req_id":"c-1","ts":1,"data":{"track_id":"t-1","max_layer":"ultra"}}"#
        let data = try IMEnvelope.decode(raw).decodedData()
        XCTAssertEqual(data["max_layer"], .string("l"), "未知层应当折成兜底值 l")
    }

    /// 越界的处理**不能一刀切**：timeout 钳边界，质量 level 折成 0 = unknown。
    func testOutOfRangeHandlingDiffersByField() throws {
        let invite = #"{"type":"call.invite","req_id":"c-1","ts":1,"data":{"callee_ids":["bob"],"media_type":"audio","timeout_sec":9999}}"#
        XCTAssertEqual(try IMEnvelope.decode(invite).decodedData()["timeout_sec"],
                       .int(IMProtocolEnums.maxTimeoutSec), "timeout 越界应当钳到上界")

        let quality = #"{"type":"room.quality","req_id":"","ts":1,"data":{"room_id":"r-1","entries":[{"participant_id":"p-1","uid":"bob","level":42}]}}"#
        let entries = try IMEnvelope.decode(quality).decodedData()["entries"]?.arrayValue
        XCTAssertEqual(entries?.first?.objectValue?["level"], .int(0),
                       "质量越界应当折成 0 = unknown，而不是钳到 6——把未知说成已断开会误导 UI")
    }

    /// 对象嵌套超过两层要拒。要塞任意结构请用 user_data（opaque 字符串）。
    func testDeepNestingIsRejected() {
        let raw = #"{"type":"sys.ping","req_id":"c-1","ts":1,"data":{"a":{"b":{"c":1}}}}"#
        XCTAssertThrowsError(try IMEnvelope.decode(raw)) { error in
            XCTAssertEqual((error as? IMRTCError)?.code, .badParams)
        }
    }
}
