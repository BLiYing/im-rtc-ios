import Foundation
import IMCallEngine

/*
 「按通话向宿主要候选人」与「主动加入」（HOST_INTEGRATION_DESIGN §3.4）。拆到独立
 extension 文件是体量红线（CONVENTIONS §2）——`IMCallController.swift` 已经排满了
 权限门、发布、红键看门狗这些既有职责，存储属性（`inviteMemberProvider` /
 `allowsManualUIDInput` / `joiningCallID` / `pendingJoinDenial`）留在主文件，
 这里只放算出来的东西与主动加入这一个独立动作。
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
     过麦克风权限门之后 `engine.joinCall` 再发 `call.join`。被拒（不存在 / 已结束 / 满员 / 宿主拒绝等）
     与 `call()` 被拒同一条路径收场——`onError` 带着错误码到 `IMCallController+Delegate.swift` 的
     `didFailWithError`，紧跟着的 `callDidEnd` 把界面收起，1409 的文案见那边。
     */
    @objc public func joinCall(_ callID: String) {
        guard imJoinCallAllowed(from: state.phase) else {
            IMRTCLog.warn("[Kit] 正在通话中，忽略 joinCall", ["call_id": callID, "phase": state.phase.rawValue])
            apply(.hint("正在通话中，无法加入"))
            return
        }
        joiningCallID = callID
        apply(.joinRequested(callID: callID, now: Date().timeIntervalSince1970))
        Task {
            // 与接听同一道权限门，但只要麦克风：加入之前不知道这通是不是视频，摄像头等用户在通话里再开。
            let outcome = await permissionGate.ensure(imPermissionDevices(mediaType: "audio", withCamera: false))
            guard await settle(outcome, onBlocked: {
                self.joiningCallID = nil
                self.apply(.dismiss)
            }) else { return }
            // 同 `placeCall`：权限门可能停在系统框上好几秒，这期间这一屏可能已经收了。
            let stillJoining = await MainActor.run(body: {
                self.state.phase == .connecting && self.state.callID == callID
            })
            guard stillJoining else {
                await MainActor.run { if self.joiningCallID == callID { self.joiningCallID = nil } }
                return
            }
            await engine.joinCall(callID)
        }
    }
}
