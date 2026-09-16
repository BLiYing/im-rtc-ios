import XCTest
@testable import IMCallKit

/**
 `ringtoneFor(_:muted:)` 的用例。**纯值语义，不需要模拟器**——判据本身放在
 `IMCallViewRules.swift`（不带 UIKit），播放动作在 `IMCallController+Ringtone.swift`
 （那半边 macOS 编不到，靠这里的纯函数测试兜底覆盖率）。
 */
final class RingtoneRulesTests: XCTestCase {

    private func state(phase: IMCallPhase, isMeeting: Bool = false) -> IMCallViewState {
        var state = IMCallViewState()
        state.phase = phase
        state.isMeeting = isMeeting
        return state
    }

    func testIncomingRings() {
        XCTAssertEqual(ringtoneFor(state(phase: .incoming), muted: false), .incoming)
    }

    func testOutgoingRingsBack() {
        XCTAssertEqual(ringtoneFor(state(phase: .outgoing), muted: false), .ringback)
    }

    func testMeetingNeverRingsEvenWhilePhaseLooksLikeIncoming() {
        // 会议正常不会走到 incoming/outgoing（`meetingJoined` 直接进 connecting），
        // 但这条判据独立判 `isMeeting`，哪怕 phase 凑巧撞上也不该响。
        XCTAssertEqual(ringtoneFor(state(phase: .incoming, isMeeting: true), muted: false), .none)
        XCTAssertEqual(ringtoneFor(state(phase: .outgoing, isMeeting: true), muted: false), .none)
        XCTAssertEqual(ringtoneFor(state(phase: .connecting, isMeeting: true), muted: false), .none)
    }

    func testMutedOverridesEverything() {
        XCTAssertEqual(ringtoneFor(state(phase: .incoming), muted: true), .none)
        XCTAssertEqual(ringtoneFor(state(phase: .outgoing), muted: true), .none)
    }

    func testOtherPhasesAreSilent() {
        XCTAssertEqual(ringtoneFor(state(phase: .idle), muted: false), .none)
        XCTAssertEqual(ringtoneFor(state(phase: .connecting), muted: false), .none)
        XCTAssertEqual(ringtoneFor(state(phase: .active), muted: false), .none)
        XCTAssertEqual(ringtoneFor(state(phase: .ended), muted: false), .none)
    }

    /// 停铃要覆盖两条路径：`.callEnd` 在响铃时直接回 idle（不经过 ended），
    /// 别的场合按正常流程走到 ended。两边都要落在 `.none`。
    func testIncomingCallEndRoutesThroughIdleNotEnded() {
        let viaReject = reduceCallView(
            state(phase: .incoming),
            .callEnd(reason: "reject", durationSec: 0))
        XCTAssertEqual(viaReject.phase, .idle)
        XCTAssertEqual(ringtoneFor(viaReject, muted: false), .none)

        let viaHangup = reduceCallView(
            state(phase: .active),
            .callEnd(reason: "hangup", durationSec: 12))
        XCTAssertEqual(viaHangup.phase, .ended)
        XCTAssertEqual(ringtoneFor(viaHangup, muted: false), .none)
    }
}
