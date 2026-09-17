import XCTest
@testable import IMCallEngine

/// `IMCallExit` 那张表与 `call_fsm.json` 逐条对照。
///
/// 表是「这个状态怎么结束」的唯一出处（挂断键、红键强制收场、迟到帧补发、帧失败收场四处都查它），
/// 向量是四端共用的契约。两边任何一处改了而另一处没跟上，这里就会红。
final class CallExitTableTests: XCTestCase {
    private let exitOps = ["reject", "cancel", "hangup"]

    /// 向量里每一步 reject / cancel / hangup：放行的发的帧与表一致；被本地拒掉的，表里那个状态也不该用这个方法。
    func testVectorExitStepsMatchTable() throws {
        let cases = try Vectors.array(try Vectors.load("call_fsm.json"), "cases")
        var checked = 0
        for testCase in cases {
            let name = testCase["name"] as? String ?? "?"
            var ctx = IMCallContext()
            ctx.state = IMCallState(rawValue: testCase["initial_state"] as? String ?? "idle") ?? .idle
            for (index, step) in (testCase["steps"] as? [[String: Any]] ?? []).enumerated() {
                let label = "[\(name)] 第 \(index + 1) 步"
                guard let input = FSMVector.makeInput(step, label: label) else { continue }
                if case let .act(op, _) = input, exitOps.contains(op) {
                    checkExitStep(state: ctx.state, op: op, step: step, label: label)
                    checked += 1
                }
                if case let .recv(type, _) = input, ctx.state == .idle, type != IMFrameType.callIncoming {
                    let wantSend = (step["send"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
                    let tableSend = IMCallExit.serverState(afterLate: type).flatMap { IMCallExit.of($0) }?.frameTypes ?? []
                    XCTAssertEqual(tableSend, wantSend, "\(label)：idle 下迟到的 \(type) 补发的帧")
                }
                ctx = IMCallMachine.reduce(ctx, input).state
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 3, "向量里的退出步骤明显变少了")
    }

    private func checkExitStep(state: IMCallState, op: String, step: [String: Any], label: String) {
        let exit = IMCallExit.of(state)
        guard step["result"] == nil else {
            XCTAssertNotEqual(exit?.op, op, "\(label)：向量在 \(state) 下本地拒掉 \(op)，表却放行")
            return
        }
        XCTAssertEqual(exit?.op, op, "\(label)：向量在 \(state) 下放行 \(op)，表不认")
        let wantSend = (step["send"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        XCTAssertEqual(exit?.frameTypes ?? [], wantSend, "\(label)：\(state) 下 \(op) 发的帧")
    }

    /// 向量声明的每个状态 × 三个退出方法，状态机的行为都与表一致（向量没走到的格子也要对）。
    func testEveryStateAndExitOpFollowsTable() throws {
        let states = try Vectors.load("call_fsm.json")["states"] as? [String] ?? []
        XCTAssertEqual(states.count, 6, "向量的状态集合变了，表要跟着看一遍")
        for raw in states {
            let state = try XCTUnwrap(IMCallState(rawValue: raw), "向量里的状态 \(raw) 引擎不认")
            var ctx = IMCallContext()
            ctx.state = state
            ctx.callID = "c-1"
            for op in exitOps {
                let out = IMCallMachine.reduce(ctx, .act(op: op, args: [:]))
                if let exit = IMCallExit.of(state), exit.op == op {
                    XCTAssertNil(out.reject, "\(raw) 下 \(op) 应放行")
                    XCTAssertEqual(out.send.map(\.type), exit.frameTypes, "\(raw) 下 \(op) 的帧")
                    XCTAssertTrue(out.send.allSatisfy { $0.data["call_id"]?.stringValue == "c-1" })
                } else {
                    XCTAssertEqual(out.reject, .invalidState, "\(raw) 下 \(op) 应本地拒成 2005")
                    XCTAssertTrue(out.send.isEmpty)
                }
            }
        }
    }

    /// 强制收场按状态挑的帧与原因就是表里那一行。
    func testForceEndUsesTable() {
        for state in [IMCallState.inviting, .ringing, .accepting, .connecting, .connected] {
            var call = IMCallContext()
            call.state = state
            call.callID = "c-1"
            let (frames, reason) = IMEngineMachine.endFrames(for: call)
            XCTAssertEqual(frames.map(\.type), IMCallExit.of(state)?.frameTypes, "\(state)")
            XCTAssertEqual(reason, IMCallExit.of(state)?.reason, "\(state)")
        }
    }

    /// 帧失败也要本地收场的集合 = 表里出现过的结束帧。
    func testAllFrameTypesAreTheThreeEndFrames() {
        XCTAssertEqual(IMCallExit.allFrameTypes,
                       [IMFrameType.callCancel, IMFrameType.callReject, IMFrameType.callHangup])
    }
}
