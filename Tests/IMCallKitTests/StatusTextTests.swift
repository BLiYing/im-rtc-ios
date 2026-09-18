import XCTest
@testable import IMCallKit

/// 通话页标题与状态行（`IMCallStatusText.swift`），原先写在 VC 里、macOS 上测不到。
final class StatusTextTests: XCTestCase {

    private func state(_ configure: (inout IMCallViewState) -> Void) -> IMCallViewState {
        var s = IMCallViewState()
        configure(&s)
        return s
    }

    func testTitleCountsSelfForGroupAndMeeting() {
        let two = [IMParticipant(uid: "bob", hasAccepted: true), IMParticipant(uid: "carol", hasAccepted: true)]
        XCTAssertEqual(imCallTitle(state { $0.isGroup = true; $0.participants = two }), "群通话 · 3 人")
        // 会议写房号、**不写人数**：右上角「👥 N」已经是人数的唯一出处。
        XCTAssertEqual(imCallTitle(state {
            $0.isMeeting = true; $0.isGroup = true; $0.participants = two; $0.roomID = "14654666"
        }), "会议 14654666", "会议优先于群通话，且标题写房号")
        // 还没拿到房号的那一瞬（进房应答之前）不显示一个空房号。
        XCTAssertEqual(imCallTitle(state { $0.isMeeting = true; $0.isGroup = true; $0.participants = two }), "会议")
        XCTAssertEqual(imCallTitle(state { $0.peerUID = "bob" }), "bob")
        XCTAssertEqual(imCallTitle(IMCallViewState()), "通话")
    }

    func testStatusLinePerPhase() {
        XCTAssertEqual(imCallStatusLine(state { $0.phase = .incoming; $0.mediaType = "video" }), "邀请你视频通话")
        XCTAssertEqual(imCallStatusLine(state { $0.phase = .incoming }), "邀请你语音通话")
        XCTAssertEqual(imCallStatusLine(state { $0.phase = .outgoing }), "正在呼叫…")
        XCTAssertEqual(imCallStatusLine(state { $0.phase = .connecting; $0.isMeeting = true }), "正在进入会议…")
        XCTAssertEqual(imCallStatusLine(state { $0.phase = .connecting }), "接通中…")
        XCTAssertEqual(imCallStatusLine(state { $0.phase = .ended; $0.isMeeting = true }), "已离开会议")
        XCTAssertEqual(imCallStatusLine(IMCallViewState()), "")
    }

    func testActiveShowsDurationFromInjectedClock() {
        let active = state { $0.phase = .active; $0.beganAt = 1_000 }
        XCTAssertEqual(imCallStatusLine(active, now: 1_065), imFormatDuration(65))
    }

    func testHintWinsOverPhase() {
        XCTAssertEqual(imCallStatusLine(state { $0.phase = .active; $0.hint = "通话已满员" }), "通话已满员")
    }

    func testEndedUsesServerDurationNotClock() {
        let ended = state { $0.phase = .ended; $0.endReason = "hangup"; $0.role = "caller"; $0.endedDurationSec = 42 }
        XCTAssertEqual(imCallStatusLine(ended, now: 9_999_999),
                       imEndReasonText("hangup", role: "caller", durationSec: 42))
    }
}
