import XCTest
import IMCallEngine
@testable import IMCallKit

/**
 「已在通话中又开始另一场」的守门（`imNewCallAllowed` / `IMCallController.blockIfBusy`）。
 真机事故（2026-09-19 17:03，Android，1v1 收成小窗后去发起群通话）：判据缺失时界面被换成另一通、没有任何提示。
 **不需要网络**：状态靠 `apply(_:)` 直接摆到「通话中」。
 */
final class BusyGuardTests: XCTestCase {

    private let allPhases: [IMCallPhase] = [.idle, .incoming, .outgoing, .connecting, .active, .ended]

    private func makeController() -> IMCallController {
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!, deviceID: "d-1", media: nil)
        return IMCallController(engine: engine)
    }

    func testOnlyIdleOrEndedMayStartANewOne() {
        for phase in allPhases {
            XCTAssertEqual(imNewCallAllowed(from: phase), phase == .idle || phase == .ended, "\(phase)")
            XCTAssertEqual(imNewCallAllowed(from: phase), imJoinCallAllowed(from: phase), "加入与发起同一条判据：\(phase)")
        }
    }

    /// 已在通话中：placeCall / joinMeeting / joinCall 都只弹提示，**界面状态一点不动**。
    func testEntriesDoNotTouchTheOngoingCall() {
        let controller = makeController()
        controller.apply(.callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false))
        let before = controller.state
        XCTAssertFalse(imNewCallAllowed(from: before.phase))

        var notices: [String] = []
        controller.noticeHandler = { notices.append($0) }

        controller.placeCall(["carol", "dave"], mediaType: "video", isGroup: true, chatGroupID: "g1")
        controller.joinMeeting(roomID: "r1", roomToken: "t")
        controller.joinCall("call-1")

        XCTAssertEqual(controller.state, before, "被拒的入口不该改界面状态")
        XCTAssertEqual(notices, [imBusyNoticeText, imBusyNoticeText, "正在通话中，无法加入"])
    }

    /// 没挂 UI（没有 noticeHandler）时退回通话界面里的 hint，不静默。
    func testFallsBackToHintWithoutUI() {
        let controller = makeController()
        controller.apply(.callPlaced(calleeIDs: ["bob"], mediaType: "audio", isGroup: false))
        controller.placeCall(["carol"], mediaType: "audio")
        XCTAssertEqual(controller.state.hint, imBusyNoticeText)
    }
}
