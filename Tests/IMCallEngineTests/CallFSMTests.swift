import XCTest
@testable import IMCallEngine

/// `call_fsm.json` —— 通话状态机的一致性向量。
///
/// 向量的铁律：**某一步没写 send / emit 就是断言为空**。
/// 多抛一次 onCallEnd、多发一帧 room.leave 都会被抓到——
/// 这正是「唯一终态帧」「便利事件只在 1v1 抛」这些不变量的机器化守卫。
final class CallFSMTests: XCTestCase {
    func testCallFSMVectors() throws {
        let vector = try Vectors.load("call_fsm.json")
        XCTAssertEqual(vector["kind"] as? String, "call_fsm")
        let states = Set(vector["states"] as? [String] ?? [])
        let cases = try Vectors.array(vector, "cases")
        XCTAssertGreaterThan(cases.count, 10, "向量条数明显变少了")

        for testCase in cases {
            run(testCase, allowedStates: states)
        }
    }

    private func run(_ testCase: [String: Any], allowedStates: Set<String>) {
        let name = testCase["name"] as? String ?? "?"
        var ctx = seedContext(testCase)
        XCTAssertTrue(allowedStates.contains(ctx.state.rawValue),
                      "[\(name)] 初始状态 \(ctx.state.rawValue) 不在向量声明的集合里")

        let steps = testCase["steps"] as? [[String: Any]] ?? []
        for (index, step) in steps.enumerated() {
            let label = "[\(name)] 第 \(index + 1) 步"
            guard let input = FSMVector.makeInput(step, label: label) else { continue }

            let result = IMCallMachine.reduce(ctx, input)
            ctx = result.state

            FSMVector.assertFrames(result.send, step["send"], label: "\(label) 的 send")
            FSMVector.assertEvents(result.emit, step["emit"], label: "\(label) 的 emit")

            if let wantState = step["state"] as? String {
                XCTAssertTrue(allowedStates.contains(wantState),
                              "\(label) 期望的状态 \(wantState) 不在向量声明的集合里")
                XCTAssertEqual(ctx.state.rawValue, wantState, "\(label) 之后的状态")
            }
        }
    }

    private func seedContext(_ testCase: [String: Any]) -> IMCallContext {
        var ctx = IMCallContext()
        ctx.state = IMCallState(rawValue: testCase["initial_state"] as? String ?? "idle") ?? .idle
        ctx.role = IMCallRole(rawValue: testCase["role"] as? String ?? "") ?? .none
        guard let context = testCase["context"] as? [String: Any] else { return ctx }
        ctx.callID = context["call_id"] as? String ?? ""
        ctx.roomID = context["room_id"] as? String ?? ""
        ctx.isGroup = (context["is_group"] as? NSNumber)?.boolValue ?? false
        return ctx
    }

}
