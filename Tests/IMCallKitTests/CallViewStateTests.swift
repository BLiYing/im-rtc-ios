import XCTest
@testable import IMCallKit

/**
 视图模型的用例。**纯值语义，不需要模拟器、不需要 Engine。**

 这一组守的是 Web 端在浏览器里真撞出来的那几条——三端同一套界面逻辑，
 同一个坑不该踩两遍：

 · 会议房里点红按钮走 hangup → 被本地拒成 2005，人退不出去；
 · `hasAudio` 默认 false → 所有人一进来都显示成静音；
 · activeSpeakers 只加不减 → 高亮一直亮着不灭；
 · connecting 一帧都不停留时，媒体就绪的信号被丢掉 → 界面永远停在「接通中」。
 */
final class CallViewStateTests: XCTestCase {

    private func reduce(_ state: IMCallViewState,
                        _ actions: [IMCallViewAction]) -> IMCallViewState {
        actions.reduce(state) { reduceCallView($0, $1) }
    }

    // MARK: - 阶段

    func testIncomingCallShowsCaller() {
        let state = reduce(IMCallViewState(), [
            .callReceived(callID: "c-1", caller: "alice", mediaType: "video", isGroup: false),
        ])
        XCTAssertEqual(state.phase, .incoming)
        XCTAssertEqual(state.peerUID, "alice")
        XCTAssertTrue(state.selfState.cameraOn, "视频来电，摄像头默认开")
        XCTAssertEqual(state.participants.map(\.uid), ["alice"])
    }

    func testGroupCallHasNoPeerUID() {
        let state = reduce(IMCallViewState(), [
            .callPlaced(calleeIDs: ["bob", "carol"], mediaType: "video", isGroup: true),
        ])
        XCTAssertEqual(state.peerUID, "", "群通话没有唯一对端")
        XCTAssertEqual(state.participants.count, 2)
        XCTAssertTrue(state.participants.allSatisfy { !$0.hasAccepted },
                      "呼出时对方还没接，格子要标成响铃中")
    }

    /// **媒体先于 callBegin 到达也要算数。**
    ///
    /// 只在「阶段正好是 connecting」时才认的话，会议场景里那个信号会被丢掉，
    /// 界面永远停在「接通中」。
    func testMediaReadyBeforeCallBeginStillReachesActive() {
        let state = reduce(IMCallViewState(), [
            .callPlaced(calleeIDs: ["bob"], mediaType: "video", isGroup: false),
            .mediaReady,
            .callBegin(callID: "c-1", roomID: "r-1", mediaType: "video",
                       isGroup: false, role: "caller", now: 100),
        ])
        XCTAssertEqual(state.phase, .active, "媒体已经就绪，不该退回 connecting")
    }

    func testMediaReadyAfterCallBeginAdvancesToActive() {
        let state = reduce(IMCallViewState(), [
            .callBegin(callID: "c-1", roomID: "r-1", mediaType: "video",
                       isGroup: false, role: "caller", now: 100),
        ])
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(reduce(state, [.mediaReady]).phase, .active)
    }

    // MARK: - 会议

    func testMeetingIsMarkedSoTheRedButtonCanTellThemApart() {
        let state = reduce(IMCallViewState(), [.meetingJoined(roomID: "r-9", now: 100)])
        XCTAssertTrue(state.isMeeting, "会议房里没有 call，红按钮必须走 leaveRoom")
        XCTAssertTrue(state.isGroup)
        XCTAssertEqual(state.callID, "", "会议没有 call_id")
        XCTAssertEqual(state.phase, .connecting)
    }

    func testRoomLeftEndsAMeeting() {
        let state = reduce(IMCallViewState(), [
            .meetingJoined(roomID: "r-9", now: 100), .mediaReady, .roomLeft,
        ])
        XCTAssertEqual(state.phase, .ended, "会议没有 callEnd，收尾只能靠 roomLeft")
    }

    /// 通话结束时房间也会被清掉，`roomLeft` 不能把已经写好的 endReason 抹掉。
    func testRoomLeftAfterCallEndKeepsTheReason() {
        let state = reduce(IMCallViewState(), [
            .callBegin(callID: "c-1", roomID: "r-1", mediaType: "audio",
                       isGroup: false, role: "caller", now: 100),
            .callEnd(reason: "hangup"),
            .roomLeft,
        ])
        XCTAssertEqual(state.endReason, "hangup")
    }

    // MARK: - 成员

    /// **默认认为有音频**。`userAudioAvailable` 只在状态变化时抛，
    /// 一开始就正常的人不会有事件——默认 false 会让所有人都显示成静音。
    func testParticipantsDefaultToHavingAudio() {
        let state = reduce(IMCallViewState(), [
            .callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false),
        ])
        XCTAssertTrue(state.participants[0].hasAudio)
        XCTAssertFalse(state.participants[0].hasVideo, "视频反过来：没收到就是没有")
    }

    func testMuteEventFlipsTheFlag() {
        let state = reduce(IMCallViewState(), [
            .callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false),
            .userAudio(uid: "bob", available: false),
        ])
        XCTAssertFalse(state.participants[0].hasAudio)
    }

    /// 事件比进房通知先到是常态，成员不存在时要先补进来。
    func testEventForUnknownUserCreatesThem() {
        let state = reduce(IMCallViewState(), [.userAudio(uid: "ghost", available: false)])
        XCTAssertEqual(state.participants.map(\.uid), ["ghost"])
        XCTAssertFalse(state.participants[0].hasAudio)
    }

    /// **activeSpeakers 是全量快照不是增量**：名单空了，高亮要灭。
    func testActiveSpeakersClearsPeopleNoLongerSpeaking() {
        var state = reduce(IMCallViewState(), [
            .callPlaced(calleeIDs: ["bob", "carol"], mediaType: "audio", isGroup: true),
            .activeSpeakers([(uid: "bob", volume: 80)]),
        ])
        XCTAssertTrue(state.participants.first { $0.uid == "bob" }!.isSpeaking)

        state = reduce(state, [.activeSpeakers([])])
        XCTAssertFalse(state.participants.contains { $0.isSpeaking }, "名单空了就该全灭")
        XCTAssertTrue(state.participants.allSatisfy { $0.volume == 0 })
    }

    func testUserLeaveRemovesTheTile() {
        let state = reduce(IMCallViewState(), [
            .callPlaced(calleeIDs: ["bob", "carol"], mediaType: "audio", isGroup: true),
            .userLeave(uid: "bob"),
        ])
        XCTAssertEqual(state.participants.map(\.uid), ["carol"])
    }

    // MARK: - 收尾

    func testDismissClearsEverything() {
        let state = reduce(IMCallViewState(), [
            .callBegin(callID: "c-1", roomID: "r-1", mediaType: "video",
                       isGroup: false, role: "caller", now: 100),
            .callEnd(reason: "hangup"),
            .dismiss,
        ])
        XCTAssertEqual(state, IMCallViewState(), "收起之后必须回到全空态")
        XCTAssertFalse(state.isVisible)
    }

    func testEndingClearsMinimizedSoTheUserSeesTheResult() {
        let state = reduce(IMCallViewState(), [
            .callBegin(callID: "c-1", roomID: "r-1", mediaType: "audio",
                       isGroup: false, role: "caller", now: 100),
            .setMinimized(true),
            .callEnd(reason: "hangup"),
        ])
        XCTAssertFalse(state.isMinimized, "结束画面要展开，收在小窗里等于没告诉用户")
    }
}

/*
 群通话里有人拒接 / 没接，**格子要收掉**。

 不收的话那一格一直挂着「（响铃中）」——从主叫的角度看，
 对方拒接就跟什么都没发生一样。群通话里没有便利事件（不变量 I7），
 `onUserReject` / `onUserNoResponse` 是唯一的信号。
 */
final class GroupOutcomeTests: XCTestCase {

    func testRejectedMemberLeavesTheGrid() {
        var state = reduceCallView(IMCallViewState(),
                                   .callPlaced(calleeIDs: ["bob", "carol"],
                                               mediaType: "video", isGroup: true))
        XCTAssertEqual(state.participants.map(\.uid), ["bob", "carol"])

        state = reduceCallView(state, .userSettled(uid: "bob"))
        XCTAssertEqual(state.participants.map(\.uid), ["carol"], "拒接的人不该还占着格子")

        state = reduceCallView(state, .userSettled(uid: "carol"))
        XCTAssertTrue(state.participants.isEmpty)
    }
}

/// 布局与层上界。**这段算术直接决定带宽**，所以单独测。
final class GridTests: XCTestCase {

    /// 正方形容器（aspect = 1）：退化成老的「尽量接近正方形」。
    func testGridPrefersSquareShapes() {
        XCTAssertEqual(imGridDimensions(1), IMGridDimensions(columns: 1, rows: 1))
        XCTAssertEqual(imGridDimensions(2), IMGridDimensions(columns: 2, rows: 1))
        // 3 人排 2×2 留一个空位，比 3×1 那种细长条好看。
        XCTAssertEqual(imGridDimensions(3), IMGridDimensions(columns: 2, rows: 2))
        XCTAssertEqual(imGridDimensions(4), IMGridDimensions(columns: 2, rows: 2))
        XCTAssertEqual(imGridDimensions(9), IMGridDimensions(columns: 3, rows: 3))
    }

    /**
     **决定列数的不是人数，是容器形状。**

     竖屏手机（宽/高 ≈ 0.7）上 2 个人必须是「上下摞」——原先固定
     `ceil(sqrt(n))` 会排成 1 行 2 列，每格半个屏宽、整个屏高，
     画面被拉成两条细长条（真机实测反馈：「很丑」）。
     同样是 2 个人，横屏电脑上 2 列才是对的。
    */
    func testGridFollowsContainerShape() {
        let phone = 0.7, desktop = 1.8

        XCTAssertEqual(imGridDimensions(2, aspect: phone),
                       IMGridDimensions(columns: 1, rows: 2), "竖屏两人要上下摞")
        XCTAssertEqual(imGridDimensions(2, aspect: desktop),
                       IMGridDimensions(columns: 2, rows: 1), "横屏两人要左右排")

        // 人多了两种形状都收敛到方阵——那时候是行列都不够用，形状说了不算。
        XCTAssertEqual(imGridDimensions(4, aspect: phone), IMGridDimensions(columns: 2, rows: 2))
        XCTAssertEqual(imGridDimensions(4, aspect: desktop), IMGridDimensions(columns: 2, rows: 2))
        XCTAssertEqual(imGridDimensions(9, aspect: phone), IMGridDimensions(columns: 3, rows: 3))
    }

    /// 挑出来的排法必须**真的是格子最大的那一种**（这是这条规则的全部意义）。
    func testGridMaximisesSquareCellSide() {
        for count in 1...IMMaxTiles {
            for aspect in [0.5, 0.7, 1.0, 1.4, 2.0] {
                let chosen = imGridDimensions(count, aspect: aspect)
                let best = squareSide(count: count, aspect: aspect, dims: chosen)
                for columns in 1...count {
                    let rows = Int(ceil(Double(count) / Double(columns)))
                    let side = squareSide(count: count, aspect: aspect,
                                          dims: IMGridDimensions(columns: columns, rows: rows))
                    XCTAssertLessThanOrEqual(side, best + 1e-9,
                        "count=\(count) aspect=\(aspect)：\(columns)×\(rows) 的格子更大")
                }
            }
        }
    }

    private func squareSide(count: Int, aspect: Double, dims: IMGridDimensions) -> Double {
        let gap = min(aspect, 1.0) * 0.02
        let cellWidth = (aspect - Double(dims.columns - 1) * gap) / Double(dims.columns)
        let cellHeight = (1.0 - Double(dims.rows - 1) * gap) / Double(dims.rows)
        return min(cellWidth, cellHeight)
    }

    func testGridClampsToOneScreen() {
        XCTAssertEqual(imGridDimensions(99), IMGridDimensions(columns: 3, rows: 3))
        XCTAssertEqual(imGridDimensions(0), IMGridDimensions(columns: 1, rows: 1))
    }

    /// 格子越小报的层越低。**漏了这一档，九宫格就是 8 路 720p。**
    func testLayerDropsAsTilesShrink() {
        XCTAssertEqual(imTileLayer(1), "h")
        XCTAssertEqual(imTileLayer(4), "m")
        XCTAssertEqual(imTileLayer(5), "l")
        XCTAssertEqual(imTileLayer(9), "l")
    }

    func testVisibleTilesTruncates() {
        XCTAssertEqual(imVisibleTiles(Array(1...5)).count, 5)
        XCTAssertEqual(imVisibleTiles(Array(1...20)).count, IMMaxTiles)
    }

    func testDurationFormat() {
        XCTAssertEqual(imFormatDuration(0), "00:00")
        XCTAssertEqual(imFormatDuration(65), "01:05")
        XCTAssertEqual(imFormatDuration(3661), "1:01:01")
        XCTAssertEqual(imFormatDuration(-5), "00:00", "负数不该画成 -1:-5")
    }
}

/// 红按钮的四向分派。**这是 Web 端真出过 bug 的地方**，所以单独测。
final class EndActionTests: XCTestCase {

    private func state(_ build: (inout IMCallViewState) -> Void) -> IMCallViewState {
        var s = IMCallViewState()
        build(&s)
        return s
    }

    /// **会议房里没有 call**：发 hangup 会被状态机本地拒成 2005，
    /// 按钮点了毫无反应、人退不出房间。
    func testMeetingLeavesTheRoomInsteadOfHangingUp() {
        let meeting = state { $0.isMeeting = true; $0.phase = .active }
        XCTAssertEqual(imEndAction(for: meeting), .leaveRoom)
    }

    /// 会议在任何阶段都是 leaveRoom——包括还没接通那会儿。
    func testMeetingAlwaysLeavesRegardlessOfPhase() {
        for phase in [IMCallPhase.connecting, .active, .outgoing] {
            let meeting = state { $0.isMeeting = true; $0.phase = phase }
            XCTAssertEqual(imEndAction(for: meeting), .leaveRoom, "\(phase) 也该是离房")
        }
    }

    func testIncomingRejects() {
        XCTAssertEqual(imEndAction(for: state { $0.phase = .incoming }), .reject)
    }

    /// **接通前只能 cancel，接通后只能 hangup**（协议 §4.4），服务端会拒掉用错的那个。
    func testOutgoingCancelsAndActiveHangsUp() {
        XCTAssertEqual(imEndAction(for: state { $0.phase = .outgoing }), .cancel)
        XCTAssertEqual(imEndAction(for: state { $0.phase = .active }), .hangup)
        XCTAssertEqual(imEndAction(for: state { $0.phase = .connecting }), .hangup)
    }
}

/// 扬声器默认值。**视频通话默认外放**：举着手机看画面时不可能贴耳朵听筒。
final class SpeakerDefaultTests: XCTestCase {
    func testVideoCallDefaultsToSpeaker() {
        let video = reduceCallView(IMCallViewState(),
                                   .callReceived(callID: "c", caller: "a", mediaType: "video", isGroup: false))
        let audio = reduceCallView(IMCallViewState(),
                                   .callReceived(callID: "c", caller: "a", mediaType: "audio", isGroup: false))
        XCTAssertTrue(video.selfState.speakerOn)
        XCTAssertFalse(audio.selfState.speakerOn, "语音通话默认听筒，跟系统电话一致")
    }

    func testMeetingDefaultsToSpeaker() {
        let meeting = reduceCallView(IMCallViewState(), .meetingJoined(roomID: "r", now: 1))
        XCTAssertTrue(meeting.selfState.speakerOn)
    }

    func testToggleSpeaker() {
        var state = reduceCallView(IMCallViewState(),
                                   .callReceived(callID: "c", caller: "a", mediaType: "audio", isGroup: false))
        state = reduceCallView(state, .setSpeaker(true))
        XCTAssertTrue(state.selfState.speakerOn)
    }
}

/**
 结束原因的文案。**这是「界面消失得很快、还不说为什么」那条反馈的正面回答。**

 服务端对不在线的被叫是**立刻结束、不振铃**（协议 §4.3：被叫压根不知道有这通电话），
 那个行为是对的——对着不在的人响 30 秒没有意义。要修的是界面：得说清楚。
 */
final class EndReasonTextTests: XCTestCase {

    func testOfflineSaysSo() {
        XCTAssertEqual(imEndReasonText("offline", role: "caller", durationSec: 0), "对方当前不在线")
    }

    /// 同一个 reason 在主叫与被叫眼里是**两句话**。
    func testReasonReadsDifferentlyPerRole() {
        XCTAssertEqual(imEndReasonText("reject", role: "caller", durationSec: 0), "对方已拒接")
        XCTAssertEqual(imEndReasonText("reject", role: "callee", durationSec: 0), "已拒接")
        XCTAssertEqual(imEndReasonText("no_answer", role: "caller", durationSec: 0), "对方无人接听")
        XCTAssertEqual(imEndReasonText("no_answer", role: "callee", durationSec: 0), "未接来电")
        XCTAssertEqual(imEndReasonText("cancel", role: "callee", durationSec: 0), "对方已取消")
    }

    func testBusyAndNetwork() {
        XCTAssertEqual(imEndReasonText("busy", role: "caller", durationSec: 0), "对方忙线中")
        XCTAssertEqual(imEndReasonText("network", role: "caller", durationSec: 30), "网络中断")
    }

    /// 接通过才显示时长；没接通的不该显示 00:00。
    func testHangupShowsDurationOnlyWhenConnected() {
        XCTAssertEqual(imEndReasonText("hangup", role: "caller", durationSec: 65), "通话结束 · 01:05")
        XCTAssertEqual(imEndReasonText("hangup", role: "caller", durationSec: 0), "通话结束")
    }

    /// 未知 reason **不能把原始英文抛给用户**——那是给日志看的。
    func testUnknownReasonFallsBackToPlainChinese() {
        XCTAssertEqual(imEndReasonText("something_new", role: "caller", durationSec: 0), "已结束")
    }

    /// 说不清的那几种要停久一点，让人看清；正常挂断谁都知道发生了什么。
    func testHoldSeconds() {
        XCTAssertEqual(imEndedHoldSeconds("hangup"), 1.5)
        XCTAssertEqual(imEndedHoldSeconds("cancel"), 1.5)
        XCTAssertEqual(imEndedHoldSeconds("offline"), 3.0)
        XCTAssertEqual(imEndedHoldSeconds("busy"), 3.0)
    }
}
