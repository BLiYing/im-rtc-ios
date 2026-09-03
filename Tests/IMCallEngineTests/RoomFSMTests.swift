import XCTest
@testable import IMCallEngine

/// `room_fsm.json` —— 房间与 Track 状态机的一致性向量。
///
/// 两点与通话向量不同：
/// 1. **状态是复合的**：房间状态 + 每个 cid 的发布状态 + 每条 track 的订阅状态。
///    三者要一起对，因为「房间还在但订阅悄悄丢了」恰恰是最难在界面上看出来的那类 bug。
/// 2. **驱动的是 engine 总状态而不是单独的房间机**：有几个用例（重连恢复、被踢）
///    的初始态同时带 room 与 call，它们要验的正是「两台机器合起来才说得清」的那部分。
final class RoomFSMTests: XCTestCase {
    func testRoomFSMVectors() throws {
        let vector = try Vectors.load("room_fsm.json")
        XCTAssertEqual(vector["kind"] as? String, "room_fsm")
        let cases = try Vectors.array(vector, "cases")
        XCTAssertGreaterThan(cases.count, 3, "向量条数明显变少了")

        for testCase in cases { run(testCase) }
    }

    private func run(_ testCase: [String: Any]) {
        let name = testCase["name"] as? String ?? "?"
        var ctx = seedContext(testCase)

        for (index, step) in (testCase["steps"] as? [[String: Any]] ?? []).enumerated() {
            let label = "[\(name)] 第 \(index + 1) 步"
            guard let input = FSMVector.makeInput(step, label: label) else { continue }

            let result = IMEngineMachine.reduce(ctx, input, nowMS: nowMS)
            ctx = result.state

            FSMVector.assertFrames(result.send, step["send"], label: "\(label) 的 send")
            FSMVector.assertEvents(result.emit, step["emit"], label: "\(label) 的 emit")
            assertState(ctx, step["state"], label: label)
        }
    }

    /// nowMS 固定成一个具体时刻：向量里合成的 onCallEnd 带时长，
    /// 用真实时钟会让断言随运行时刻漂。
    private let nowMS: Int64 = 1_756_876_817_000

    private func seedContext(_ testCase: [String: Any]) -> IMEngineContext {
        var ctx = IMEngineContext()
        guard let initial = testCase["initial_state"] as? [String: Any] else { return ctx }

        ctx.room.state = IMRoomState(rawValue: initial["room"] as? String ?? "idle") ?? .idle
        ctx.room.roomID = "r-1"
        for (cid, raw) in initial["publish"] as? [String: String] ?? [:] {
            ctx.room.publish[cid] = IMPublishState(rawValue: raw)
            // 向量里的初始 publish 用 cid 作键，这里补上 cid → track_id 的映射，
            // 否则 unpublish 找不到该把哪条标成 unpublishing。
            ctx.room.publishTrackIDs[cid] = "t-7"
        }
        for (trackID, raw) in initial["subscribe"] as? [String: String] ?? [:] {
            ctx.room.subscribe[trackID] = IMSubscribeState(rawValue: raw)
            ctx.room.remoteTracks[trackID] = IMRemoteTrack(uid: "bob", kind: "video",
                                                           participantID: "p-1")
        }

        ctx.call.state = IMCallState(rawValue: initial["call"] as? String ?? "idle") ?? .idle
        ctx.call.callID = "call-1"
        ctx.call.roomID = "r-1"
        ctx.call.connectedAtMS = ctx.call.state == .connected ? nowMS - 5_000 : 0
        return ctx
    }

    /// assertState 比对复合状态。
    ///
    /// 订阅状态里的 `none` 表示「这条 track 不该有订阅记录」——
    /// 用一个值表达「不存在」比让向量写 null 干净（协议里本来也没有 null）。
    private func assertState(_ ctx: IMEngineContext, _ want: Any?, label: String) {
        guard let want = want as? [String: Any] else { return }
        if let room = want["room"] as? String {
            XCTAssertEqual(ctx.room.state.rawValue, room, "\(label) 之后的房间状态")
        }
        if let call = want["call"] as? String {
            XCTAssertEqual(ctx.call.state.rawValue, call, "\(label) 之后的通话状态")
        }
        // publish / subscribe 按**全等**比而不是子集：向量里是完整写出来的，
        // 用子集比会让「多了一条没清掉的订阅」溜过去，而那正是最容易出的错。
        if let publish = want["publish"] as? [String: String] {
            XCTAssertEqual(ctx.room.publish.mapValues(\.rawValue), publish, "\(label) 的 publish")
        }
        if let subscribe = want["subscribe"] as? [String: String] {
            XCTAssertEqual(ctx.room.subscribe.mapValues(\.rawValue), subscribe,
                           "\(label) 的 subscribe")
        }
    }
}
