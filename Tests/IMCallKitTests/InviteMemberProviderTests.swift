import XCTest
import IMCallEngine
@testable import IMCallKit

/**
 M2：`IMInviteContext` / `IMInviteCandidate` / `IMCallController` 与 provider 相关的接线
 （HOST_INTEGRATION_DESIGN §3.4）。**不需要网络**：`IMCallController` 内部靠 `apply(_:)`
 驱动状态（module-internal，测试与实现同一个 target 能直接调），不需要真的连上服务端。
 */
final class InviteMemberProviderTests: XCTestCase {

    private func makeController() -> IMCallController {
        let engine = IMCallEngine(url: URL(string: "ws://test/v1/ws")!, deviceID: "d-1", media: nil)
        return IMCallController(engine: engine)
    }

    // MARK: - IMInviteCandidate 扩字段

    func testCandidateDefaultsAreBackwardCompatible() {
        let candidate = IMInviteCandidate(uid: "bob")
        XCTAssertEqual(candidate.name, "bob", "没给名字时退化成 uid（旧行为不变）")
        XCTAssertNil(candidate.avatarURL)
        XCTAssertNil(candidate.subtitle)
        XCTAssertTrue(candidate.selectable)
        XCTAssertNil(candidate.unselectableReason)
    }

    func testCandidateCarriesTheNewFields() {
        let url = URL(string: "https://example.com/a.png")!
        let candidate = IMInviteCandidate(uid: "carol", name: "Carol", avatarURL: url,
                                          subtitle: "产品部", selectable: false,
                                          unselectableReason: "已被禁言")
        XCTAssertEqual(candidate.name, "Carol")
        XCTAssertEqual(candidate.avatarURL, url)
        XCTAssertEqual(candidate.subtitle, "产品部")
        XCTAssertFalse(candidate.selectable)
        XCTAssertEqual(candidate.unselectableReason, "已被禁言")
    }

    // MARK: - IMInviteContext

    /// `inviteContext` 的 `participantUIDs` 含自己；`slotsLeft` 与 `imInviteSlotsLeft` 同一个数。
    func testInviteContextReflectsCurrentCallState() {
        let controller = makeController()
        controller.apply(.callBegin(callID: "call-1", roomID: "r-1", mediaType: "video",
                                    isGroup: true, role: "caller", now: 1))
        controller.apply(.callContext(caller: "alice", chatGroupID: "g-42", userData: "payload"))
        controller.apply(.userEnter(uid: "bob"))

        let ctx = controller.inviteContext
        XCTAssertEqual(ctx.callID, "call-1")
        XCTAssertEqual(ctx.chatGroupID, "g-42")
        XCTAssertEqual(ctx.userData, "payload")
        XCTAssertEqual(ctx.callerUID, "alice")
        XCTAssertEqual(ctx.mediaType, "video")
        XCTAssertEqual(Set(ctx.participantUIDs), ["", "bob"], "自己 uid 未登录时是空串，也要在名单里占一位")
        XCTAssertEqual(ctx.slotsLeft, imInviteSlotsLeft(for: controller.state))
    }

    // MARK: - canStartInvite：本端状态 × 宿主权限规则

    private final class FakeProvider: IMInviteMemberProvider {
        var allowsInvite = true
        func inviteCandidates(for context: IMInviteContext, query: String, cursor: String?,
                              completion: @escaping IMInviteCandidatesCompletion) {
            completion([], nil, nil)
        }
        func canInvite(in context: IMInviteContext) -> Bool { allowsInvite }
    }

    func testCanStartInviteChecksLocalStateFirst() {
        let controller = makeController()
        controller.apply(.callBegin(callID: "c", roomID: "r", mediaType: "audio",
                                    isGroup: true, role: "caller", now: 1))
        XCTAssertTrue(controller.canStartInvite(), "没有 provider 时默认放行")

        controller.apply(.inviteDenied) // 本端已不在通话里（1407）
        XCTAssertFalse(controller.canStartInvite(), "本端状态先拦一道，provider 都不用问")
    }

    func testCanStartInviteAsksTheProviderWhenLocalStateAllows() {
        let controller = makeController()
        controller.apply(.callBegin(callID: "c", roomID: "r", mediaType: "audio",
                                    isGroup: true, role: "caller", now: 1))
        let provider = FakeProvider()
        controller.inviteMemberProvider = provider
        XCTAssertTrue(controller.canStartInvite())

        provider.allowsInvite = false
        XCTAssertFalse(controller.canStartInvite(), "宿主的权限规则（例：群禁言）能单独拦下")
    }

    // MARK: - joinCall：先进「接通中…」，1409 按专门文案收起

    func testJoinCallEntersConnectingPhase() {
        let controller = makeController()
        controller.joinCall("call-77a1")
        XCTAssertEqual(controller.state.phase, .connecting)
        XCTAssertEqual(controller.state.callID, "call-77a1")
        XCTAssertEqual(controller.state.role, "callee")
    }

    /// 1409 拒绝加入：`didFailWithError` 记一次「正在加入」，随后 `callDidEnd(reason:"error")`
    /// 被改写成本地伪原因 `join_denied`，界面显示专门那句文案而不是笼统的「已结束」。
    func testJoinDeniedShowsDedicatedReasonThenEnds() {
        let controller = makeController()
        let engine = controller.engine
        controller.joinCall("call-77a1")

        let error = NSError(domain: IMRTCErrorDomain, code: IMErrorCode.inviteDenied.rawValue, userInfo: nil)
        controller.callEngine(engine, didFailWithError: error)
        controller.callEngine(engine, callDidEnd: "call-77a1", reason: "error", durationSec: 0, endedBy: "")

        XCTAssertEqual(controller.state.phase, .ended)
        XCTAssertEqual(controller.state.endReason, "join_denied")
        XCTAssertEqual(imEndReasonText(controller.state.endReason, role: "callee", durationSec: 0),
                       "无法加入该通话")
    }

    /// 加人（不是加入）被 1409 拒绝：只提示，不影响当前通话——与 join_denied 是两条不同的路径。
    func testInviteMoreDeniedOnlyHints() {
        let controller = makeController()
        let engine = controller.engine
        controller.apply(.callBegin(callID: "c", roomID: "r", mediaType: "audio",
                                    isGroup: true, role: "caller", now: 1))
        let error = NSError(domain: IMRTCErrorDomain, code: IMErrorCode.inviteDenied.rawValue, userInfo: nil)
        controller.callEngine(engine, didFailWithError: error)

        XCTAssertEqual(controller.state.hint, "对方暂时无法被邀请")
        XCTAssertNotEqual(controller.state.phase, .ended, "没有触发 callDidEnd，通话继续")
    }

    // MARK: - joinCall 守门（2026-09-15 代码审查）

    /// 通话中再调 joinCall：不动当前这通电话的界面，只提示。
    func testJoinCallWhileInCallKeepsCurrentCall() {
        let controller = makeController()
        controller.apply(.callBegin(callID: "c", roomID: "r", mediaType: "audio",
                                    isGroup: true, role: "caller", now: 1))
        let phaseBefore = controller.state.phase
        controller.joinCall("call-77a1")
        XCTAssertEqual(controller.state.phase, phaseBefore)
        XCTAssertEqual(controller.state.callID, "c")
        XCTAssertEqual(controller.state.hint, "正在通话中，无法加入")
        XCTAssertNil(controller.joiningCallID)
    }

    /// 连点两下：第二下被守门挡住，不会把第一下的加入改成另一通。
    func testSecondJoinCallIsIgnored() {
        let controller = makeController()
        controller.joinCall("call-a")
        controller.joinCall("call-b")
        XCTAssertEqual(controller.state.callID, "call-a")
        XCTAssertEqual(controller.joiningCallID, "call-a")
    }

    /// Engine 本地就拒掉的加入（2005 / 2007）没有 callDidEnd：Kit 自己收回「接通中…」。
    func testLocalJoinRejectionDismisses() {
        let controller = makeController()
        controller.joinCall("call-77a1")
        let error = NSError(domain: IMRTCErrorDomain, code: IMErrorCode.notLoggedIn.rawValue, userInfo: nil)
        controller.callEngine(controller.engine, didFailWithError: error)
        XCTAssertEqual(controller.state.phase, .idle)
        XCTAssertNil(controller.joiningCallID)
    }

    /// 守门判据本身：只有空闲或停在结束画面时放行。
    func testJoinCallAllowedOnlyFromIdleOrEnded() {
        XCTAssertTrue(imJoinCallAllowed(from: .idle))
        XCTAssertTrue(imJoinCallAllowed(from: .ended))
        for phase in [IMCallPhase.incoming, .outgoing, .connecting, .active] {
            XCTAssertFalse(imJoinCallAllowed(from: phase), "\(phase) 时已经在一场里")
        }
    }
}
