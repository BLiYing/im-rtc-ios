import XCTest
@testable import IMCallEngine

/*
 把 `im-rtc-server/docs/conformance/` 下的向量跑成 Swift 测试。

 **四仓跑同一份向量**——这是「协议在四种语言里行为一致」的唯一机器化证明。
 写 TS 实现时就靠它当场抓到过一处 Go/TS 漂移（数字按字面量判 vs 按值判）。

 这些测试**不需要模拟器**：整个协议层不碰 UIKit、不碰 libwebrtc，
 `swift test` 在 macOS 上直接跑。这正是 Package.swift 把媒体实现挡在 Engine 之外的理由。
 */
final class EnvelopeConformanceTests: XCTestCase {
    func testEnvelopeVectors() throws {
        let vector = try Vectors.load("envelope.json")
        let cases = try Vectors.array(vector, "cases")
        XCTAssertGreaterThan(cases.count, 20, "向量条数明显变少了，是不是加载错文件了")

        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            guard let input = testCase["input"] as? String,
                  let expect = testCase["expect"] as? [String: Any] else {
                XCTFail("[\(name)] 向量结构不对")
                continue
            }
            let shouldSucceed = (expect["ok"] as? NSNumber)?.boolValue ?? false
            if shouldSucceed {
                assertDecodes(name: name, input: input, expect: expect)
            } else {
                assertRejects(name: name, input: input, expect: expect)
            }
        }
    }

    private func assertDecodes(name: String, input: String, expect: [String: Any]) {
        do {
            let envelope = try IMEnvelope.decode(input)
            if let type = expect["type"] as? String {
                XCTAssertEqual(envelope.type, type, "[\(name)] type")
            }
            if let reqID = expect["req_id"] as? String {
                XCTAssertEqual(envelope.reqID, reqID, "[\(name)] req_id")
            }
            if let ts = expect["ts"] as? NSNumber {
                XCTAssertEqual(envelope.timestampMS, ts.int64Value, "[\(name)] ts")
            }
            guard let wantData = expect["data"] as? [String: Any] else { return }
            // 已登记的帧比**解出来的 data**（含默认值），未登记的帧只能比原始 data。
            let actual = (try? envelope.decodedData()) ?? envelope.data
            expectSubset(.object(actual), wantData, path: "[\(name)] data")
        } catch {
            XCTFail("[\(name)] 本该解析成功，却失败了：\(error)")
        }
    }

    private func assertRejects(name: String, input: String, expect: [String: Any]) {
        let wantError = expect["error"] as? String ?? ""
        do {
            let envelope = try IMEnvelope.decode(input)
            // 有些违规只有到帧级才判得出来（比如 bool 写成了 1）。
            _ = try envelope.decodedData()
            XCTFail("[\(name)] 本该被拒（\(wantError)），却解析成功了")
        } catch let error as IMRTCError {
            XCTAssertEqual(error.code.name, wantError, "[\(name)] 错误码")
        } catch {
            XCTFail("[\(name)] 抛出了非协议错误：\(error)")
        }
    }

    /// 默认值向量：「可选字段用省略表达，接收方按默认值填」（§2.4 规则 2）。
    ///
    /// **这一条是三端都踩过的坑的反面**：直接发零值结构体会把 `auto_subscribe`
    /// 写成 false，人进了房却收不到任何流。
    func testDefaultCases() throws {
        let vector = try Vectors.load("envelope.json")
        let cases = try Vectors.array(vector, "default_cases")
        XCTAssertGreaterThan(cases.count, 5, "默认值向量条数不对")

        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            guard let type = testCase["type"] as? String,
                  let inputData = testCase["input_data"] as? String,
                  let expectData = testCase["expect_data"] as? [String: Any],
                  let fields = IMFrameRegistry.fields(for: type) else {
                XCTFail("[\(name)] 向量结构不对，或帧 \(testCase["type"] ?? "?") 没登记")
                continue
            }
            do {
                guard let raw = try IMJSON.parse(inputData).objectValue else {
                    XCTFail("[\(name)] input_data 不是对象")
                    continue
                }
                let decoded = try FieldCodec.decode(fields, raw)
                expectSubset(.object(decoded), expectData, path: "[\(name)]")
            } catch {
                XCTFail("[\(name)] 解析失败：\(error)")
            }
        }
    }
}

final class ErrorCodeConformanceTests: XCTestCase {
    /// 错误码表逐条核对：code、name、msg、retryable、是否上线路，一个都不能差。
    ///
    /// msg 之所以也进契约：同一个码在三个仓里打出三种说法，联调时就没法搜。
    func testErrorCodeTable() throws {
        let vector = try Vectors.load("error_codes.json")
        try assertGroup(vector, "wire", isLocal: false)
        try assertGroup(vector, "local", isLocal: true)

        let wire = try Vectors.array(vector, "wire")
        let local = try Vectors.array(vector, "local")
        XCTAssertEqual(IMErrorCode.definitions.count, wire.count + local.count,
                       "本仓的错误码数量与向量对不上——多了或少了都是漂移")
    }

    private func assertGroup(_ vector: [String: Any], _ key: String, isLocal: Bool) throws {
        for entry in try Vectors.array(vector, key) {
            let name = entry["name"] as? String ?? "?"
            guard let rawCode = (entry["code"] as? NSNumber)?.intValue,
                  let code = IMErrorCode(rawValue: rawCode) else {
                XCTFail("本仓没有错误码 \(entry["code"] ?? "?") (\(name))")
                continue
            }
            XCTAssertEqual(code.name, name, "code \(rawCode) 的 name")
            XCTAssertEqual(code.message, entry["msg"] as? String, "code \(rawCode) 的 msg")
            XCTAssertEqual(code.isRetryable, (entry["retryable"] as? NSNumber)?.boolValue,
                           "code \(rawCode) 的 retryable")
            XCTAssertEqual(code.isLocal, isLocal, "code \(rawCode) 是否只在本地")
        }
    }
}

final class ReasonConformanceTests: XCTestCase {
    func testReasonSet() throws {
        let vector = try Vectors.load("reasons.json")
        let reasons = try Vectors.array(vector, "reasons")
        XCTAssertEqual(IMCallEndReason.allCases.count, reasons.count, "reason 数量对不上")
        for entry in reasons {
            let wire = entry["value"] as? String ?? "?"
            XCTAssertEqual(IMCallEndReason.from(wire: wire).wireValue, wire,
                           "reason \(wire) 没有对应的枚举项")
        }
    }

    /// 不认识的 reason 一律折成兜底值——这是「新增 reason 不算破坏兼容」的前提。
    func testUnknownReasonFallsBack() throws {
        let vector = try Vectors.load("reasons.json")
        let fallback = vector["unknown_fallback"] as? String ?? "error"
        XCTAssertEqual(IMCallEndReason.from(wire: "something_new_in_2027").wireValue, fallback)
    }

    func testGroupDominantReason() throws {
        let vector = try Vectors.load("reasons.json")
        let priority = vector["group_dominant_priority"] as? [String] ?? []
        XCTAssertEqual(IMCallOutcome.groupDominantPriority.map(\.wireValue), priority,
                       "群主导优先级顺序与向量不一致")

        for testCase in try Vectors.array(vector, "group_dominant_cases") {
            let name = testCase["name"] as? String ?? "?"
            let outcomes = (testCase["member_outcomes"] as? [String] ?? [])
                .map { IMCallEndReason.from(wire: $0) }
            XCTAssertEqual(IMCallOutcome.dominant(outcomes).wireValue,
                           testCase["expect"] as? String, "[\(name)]")
        }
    }

    /// 时长**向下取整不是四舍五入**：1999ms 是 1 秒不是 2 秒。
    func testDurationCases() throws {
        let vector = try Vectors.load("reasons.json")
        for testCase in try Vectors.array(vector, "duration_cases") {
            let name = testCase["name"] as? String ?? "?"
            let connected = (testCase["connected_at_ms"] as? NSNumber)?.int64Value ?? 0
            let ended = (testCase["ended_at_ms"] as? NSNumber)?.int64Value ?? 0
            let want = (testCase["expect_duration_sec"] as? NSNumber)?.int64Value ?? -1
            XCTAssertEqual(IMCallOutcome.durationSec(connectedAtMS: connected, endedAtMS: ended),
                           want, "[\(name)]")
        }
    }
}
