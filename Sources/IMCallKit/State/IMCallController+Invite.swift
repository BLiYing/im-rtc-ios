import Foundation
import IMCallEngine

/*
 「按通话向宿主要候选人」与「主动加入」（HOST_INTEGRATION_DESIGN §3.4）。拆到独立
 extension 文件是体量红线（CONVENTIONS §2）——`IMCallController.swift` 已经排满了
 权限门、发布、红键看门狗这些既有职责，存储属性（`inviteMemberProvider` /
 `allowsManualUIDInput`）留在主文件，这里只放算出来的东西、主动加入这一个独立动作，
 以及加人 / 加入被拒时怎么从 throw 出来的码挑文案。
 */
extension IMCallController {

    /// inviteContext 是此刻这通电话的邀请上下文（§3.4「共同语义」），交给 provider 用。
    @objc public var inviteContext: IMInviteContext {
        IMInviteContext(
            callID: state.callID, chatGroupID: state.chatGroupID, userData: state.userData,
            callerUID: state.callerUID, mediaType: state.mediaType,
            participantUIDs: [engine.uid] + state.participants.map(\.uid),
            slotsLeft: imInviteSlotsLeft(for: state))
    }

    /// canStartInvite 综合本端此刻在不在通话里（`state.canInvite`）与宿主的权限规则
    /// （`inviteMemberProvider.canInvite(in:)`，默认 true）。
    @objc public func canStartInvite() -> Bool {
        guard state.canInvite else { return false }
        return inviteMemberProvider?.canInvite?(in: inviteContext) ?? true
    }

    /**
     joinCall 主动加入一通正在进行的群通话（HOST_INTEGRATION_DESIGN §3.4）。

     **已经在一场里时不接**（只提示，见 `imJoinCallAllowed`）；否则先进「接通中…」界面（`.joinRequested`），
     过麦克风权限门之后 `engine.joinCall` 再发 `call.join`。被拒（不存在 / 已结束 / 满员 / 宿主拒绝等）时
     Engine 先抛 `callDidEnd(.error)` 把界面收起，再把码 throw 回来——一律显示「无法加入该通话」，见 `handleJoinCallFailure(_:callID:)`。
     */
    @objc public func joinCall(_ callID: String) {
        guard !blockIfBusy("正在通话中，无法加入") else { return }
        apply(.joinRequested(callID: callID, now: Date().timeIntervalSince1970))
        Task {
            // 与接听同一道权限门，但只要麦克风：加入之前不知道这通是不是视频，摄像头等用户在通话里再开。
            let outcome = await permissionGate.ensure(imPermissionDevices(mediaType: "audio", withCamera: false))
            guard await settle(outcome, onBlocked: { self.apply(.dismiss) }) else { return }
            // 同 `placeCall`：权限门可能停在系统框上好几秒，这期间这一屏可能已经收了。
            let stillJoining = await MainActor.run(body: {
                self.state.phase == .connecting && self.state.callID == callID
            })
            guard stillJoining else { return }
            do {
                try await engine.joinCall(callID)
            } catch {
                imLogRejected("joinCall", error)
                await MainActor.run { self.handleJoinCallFailure(error, callID: callID) }
            }
        }
    }

    /**
     handleJoinCallFailure 按 `engine.joinCall` throw 出来的错误收尾。**主线程调**。

     **任何失败都是同一句「无法加入该通话」**（不按码细分，与 Web `joinDeniedTextFor`、Android `IMKitResults.joinCall` 一致）：
     结束原因改写成本地伪原因 `join_denied`。
     - 服务端拒绝（1401 / 1402 / 1202 / 1408 / 1409…）：Engine 刚抛过的 `callDidEnd(.error)` 已经把界面收到结束画面，这里只改原因。
     - 本地就拒掉的（2005 状态不对 / 已销毁）没有 `callDidEnd`：这一屏还停在「接通中…」，同样进结束画面。
     这一屏已经不是这通电话（用户先收起了、或换成了别的来电）时不动。
     */
    func handleJoinCallFailure(_ error: Error, callID: String) {
        guard state.callID == callID, state.phase == .connecting || state.phase == .ended else { return }
        apply(.callEnd(reason: "join_denied", durationSec: 0))
    }

    /**
     handleInviteMoreFailure 按 `engine.inviteMore` throw 出来的码收尾。**主线程调**。

     满员出提示；本端已不在通话里（1407）把入口藏掉；宿主拒绝（1409）出另一句提示。
     **不管哪种失败都把这一批占位格收回来**（超时 / 断线也一样）；通话本身不受影响。
     */
    func handleInviteMoreFailure(_ error: Error) {
        switch imRTCErrorCode(error) {
        case IMErrorCode.roomFull.rawValue:
            apply(.hint("通话已满员（最多 9 人）"))
        case IMErrorCode.notCallOwner.rawValue:
            apply(.inviteDenied)
        case IMErrorCode.inviteDenied.rawValue:
            apply(.hint("对方暂时无法被邀请"))
        default:
            break
        }
        revokeLastInvite()
    }
}

/// imRTCErrorCode 取 Engine 方法 throw 出来的错误码；不是本 SDK 的错误时返回 nil。
func imRTCErrorCode(_ error: Error) -> Int? {
    let ns = error as NSError
    return ns.domain == IMRTCErrorDomain ? ns.code : nil
}

/// imLogRejected 给「界面收起靠回调、这里只留痕」的那几处 catch 用。
func imLogRejected(_ what: String, _ error: Error) {
    IMRTCLog.warn("[Kit] \(what)失败", ["code": imRTCErrorCode(error).map(String.init) ?? "", "err": String(describing: error)])
}
