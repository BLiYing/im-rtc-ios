import XCTest
@testable import IMCallEngine

/// 两份 FSM 向量共用的比对工具。
///
/// 抽出来不只是省几行：两个 runner 各抄一份的话，
/// 「省略即断言为空」这条最关键的规矩迟早在其中一份里被改松。
enum FSMVector {
    static func makeInput(_ step: [String: Any], label: String) -> IMMachineInput? {
        if let act = step["act"] as? [String: Any] {
            let args = jsonObject(act["args"]) ?? [:]
            return .act(op: act["op"] as? String ?? "", args: args)
        }
        if let recv = step["recv"] as? [String: Any] {
            let data = jsonObject(recv["data"]) ?? [:]
            return .recv(type: recv["type"] as? String ?? "", data: data)
        }
        if let name = step["internal"] as? String {
            // args 可选（`publish_failed` 的 cid、`publish_deferred` 的整条 publish data）。
            return .internalEvent(name: name, args: jsonObject(step["args"]) ?? [:])
        }
        XCTFail("\(label): 一步里必须有 act / recv / internal 之一")
        return nil
    }

    /// 把向量里的 JSON 片段转成 IMJSON。
    ///
    /// **不走 IMJSON.parse 的严格检查**：向量里的期望值是给人读的，
    /// 不是线路数据，没必要也不应该在这里跑编码硬规则。
    static func jsonObject(_ raw: Any?) -> [String: IMJSON]? {
        guard let dict = raw as? [String: Any] else { return nil }
        var out: [String: IMJSON] = [:]
        for (key, value) in dict {
            if let converted = jsonValue(value) { out[key] = converted }
        }
        return out
    }

    static func jsonValue(_ raw: Any) -> IMJSON? {
        if let text = raw as? String { return .string(text) }
        if let number = raw as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue)
                : .int(number.int64Value)
        }
        if let list = raw as? [Any] { return .array(list.compactMap { jsonValue($0) }) }
        if let dict = raw as? [String: Any] { return jsonObject(dict).map { IMJSON.object($0) } }
        return nil
    }

    static func assertFrames(_ actual: [IMOutgoingFrame], _ want: Any?, label: String) {
        let wanted = want as? [[String: Any]] ?? []
        XCTAssertEqual(actual.count, wanted.count,
                       "\(label) 条数（实际发了 \(actual.map(\.type))）")
        for (index, expected) in wanted.enumerated() where index < actual.count {
            XCTAssertEqual(actual[index].type, expected["type"] as? String, "\(label)[\(index)] 类型")
            if let data = expected["data"] {
                expectSubset(.object(actual[index].data), data, path: "\(label)[\(index)] data")
            }
        }
    }

    /// assertResult 比对 `act` 步骤的本地拒绝结果。**省略 = 断言没有本地拒绝**（2.0.0，
    /// server `docs/design/ACTION_RESULT_DESIGN.md`）：本地拒绝只进 result，不许同时抛 onError（emit 那边会抓到）。
    static func assertResult(_ actual: IMErrorCode?, _ want: Any?, label: String) {
        guard let expected = want as? [String: Any] else {
            XCTAssertNil(actual, "\(label)：向量没写 result，却被本地拒绝成 \(actual.map { $0.name } ?? "")")
            return
        }
        XCTAssertEqual(actual?.rawValue, (expected["code"] as? NSNumber)?.intValue, "\(label) 的码")
        XCTAssertEqual(actual?.name, expected["name"] as? String, "\(label) 的 name")
    }

    static func assertEvents(_ actual: [IMEmittedEvent], _ want: Any?, label: String) {
        let wanted = want as? [[String: Any]] ?? []
        XCTAssertEqual(actual.count, wanted.count,
                       "\(label) 条数（实际抛了 \(actual.map(\.callback))）")
        for (index, expected) in wanted.enumerated() where index < actual.count {
            XCTAssertEqual(actual[index].callback, expected["cb"] as? String, "\(label)[\(index)] 回调名")
            if let args = expected["args"] {
                expectSubset(.object(actual[index].args), args, path: "\(label)[\(index)] args")
            }
        }
    }
}
