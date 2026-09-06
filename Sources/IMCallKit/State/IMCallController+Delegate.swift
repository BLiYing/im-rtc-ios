import Foundation
import IMCallEngine

/*
 回调表的实现。**每一条都只用 delegate 给的参数**——没有一处去 engine 里"多问一句"。
 */
extension IMCallController: IMCallEngineDelegate {
    // MARK: 连接（顶部橙条：正在重连 / 连接已断开，规范 §08）

    public func callEngine(_ engine: IMCallEngine, didConnect sessionID: String, resumed: Bool) {
        apply(.connection(.ok))
    }

    public func callEngine(_ engine: IMCallEngine, didDisconnect code: Int, willReconnect: Bool) {
        apply(.connection(willReconnect ? .reconnecting : .lost))
    }

    public func callEngineDidGetKickedOut(_ engine: IMCallEngine) {
        apply(.connection(.lost))
    }

    /// 加人的两条失败分支（交互稿 §05）：满员出提示；非主叫把入口藏掉。别的错误码由宿主处理。
    public func callEngine(_ engine: IMCallEngine, didFailWithError error: NSError) {
        switch error.code {
        case IMErrorCode.roomFull.rawValue:
            apply(.hint("通话已满员（最多 9 人）"))
            revokeLastInvite()
        case IMErrorCode.notCallOwner.rawValue:
            apply(.inviteDenied)
            revokeLastInvite()
        default:
            break
        }
    }

    // MARK: 来电与拨出

    public func callEngine(_ engine: IMCallEngine, didReceiveCall callID: String,
                           caller: String, calleeIDs: [String], mediaType: String, isGroup: Bool) {
        // 名单里含自己，摆格子之前先去掉——「自己」不是远端成员。
        let others = calleeIDs.filter { $0 != engine.uid }
        apply(.callReceived(callID: callID, caller: caller, calleeIDs: others,
                            mediaType: mediaType, isGroup: isGroup))
    }

    /// 通话中有人打进来，服务端已经替我们回了忙线——**只提示，不动当前通话**。
    public func callEngine(_ engine: IMCallEngine, missedCall callID: String,
                           caller: String, reason: String) {
        apply(.hint("\(caller) 来电，已自动回复忙线"))
    }

    public func callEngine(_ engine: IMCallEngine, callDidBegin callID: String, roomID: String,
                           mediaType: String, isGroup: Bool, role: String) {
        apply(.callBegin(callID: callID, roomID: roomID, mediaType: mediaType,
                         isGroup: isGroup, role: role, now: Date().timeIntervalSince1970))
    }

    public func callEngine(_ engine: IMCallEngine, callDidEnd callID: String, reason: String,
                           durationSec: Int, endedBy: String) {
        apply(.callEnd(reason: reason))
    }

    // 四个便利事件只在 1v1 抛，随后必有 callDidEnd——所以这里只做提示，**不改阶段**。
    public func callEngine(_ engine: IMCallEngine, callWasRejectedBy uid: String) { apply(.hint("\(uid) 已拒接")) }
    public func callEngine(_ engine: IMCallEngine, calleeIsBusy uid: String) { apply(.hint("\(uid) 忙线中")) }
    public func callEngine(_ engine: IMCallEngine, calleeDidNotAnswer uid: String) { apply(.hint("\(uid) 无应答")) }
    public func callEngine(_ engine: IMCallEngine, callWasCancelledBy uid: String) { apply(.hint("\(uid) 取消了呼叫")) }

    /// 他设备处理了：来电页会随后收到 callDidEnd 而静默消失，这里**不弹提示**（交互稿 §06）。
    public func callEngine(_ engine: IMCallEngine, callHandledOnOtherDevice callID: String, action: String) {}

    // MARK: 房间

    // 会议没有 callDidEnd，收尾只能靠这两条。漏订阅的话离房成功了界面还挂在那儿。
    public func callEngine(_ engine: IMCallEngine, didLeaveRoom roomID: String) { apply(.roomLeft) }
    public func callEngine(_ engine: IMCallEngine, roomDidClose roomID: String, reason: String) { apply(.roomLeft) }
    public func callEngine(_ engine: IMCallEngine, didJoinRoom roomID: String) { apply(.mediaReady) }
    public func callEngine(_ engine: IMCallEngine, didReceiveFirstVideoFrame uid: String, trackID: String) {
        apply(.mediaReady)
    }

    // MARK: 成员

    public func callEngine(_ engine: IMCallEngine, userDidEnter uid: String) { apply(.userEnter(uid: uid)) }
    public func callEngine(_ engine: IMCallEngine, userDidLeave uid: String) { apply(.userLeave(uid: uid)) }
    public func callEngine(_ engine: IMCallEngine, userDidAccept uid: String) { apply(.userAccept(uid: uid)) }

    // 拒接与无应答要在格子上写明终局再收掉——直接收的话，从主叫的角度看拒接就跟什么都没发生一样。
    public func callEngine(_ engine: IMCallEngine, userDidReject uid: String) {
        apply(.userSettled(uid: uid, outcome: .rejected))
    }

    public func callEngine(_ engine: IMCallEngine, userDidNotRespond uid: String) {
        apply(.userSettled(uid: uid, outcome: .noAnswer))
    }

    public func callEngine(_ engine: IMCallEngine, user uid: String, audioAvailable available: Bool) {
        apply(.userAudio(uid: uid, available: available))
    }

    public func callEngine(_ engine: IMCallEngine, user uid: String, videoAvailable available: Bool) {
        apply(.userVideo(uid: uid, available: available))
    }

    public func callEngine(_ engine: IMCallEngine, activeSpeakersDidChange speakers: [[String: Any]]) {
        apply(.activeSpeakers(speakers.map {
            (uid: $0["uid"] as? String ?? "", volume: ($0["volume"] as? NSNumber)?.intValue ?? 0)
        }))
    }

    public func callEngine(_ engine: IMCallEngine, networkQualityDidChange entries: [[String: Any]]) {
        apply(.networkQuality(entries.map {
            (uid: $0["uid"] as? String ?? "", level: ($0["level"] as? NSNumber)?.intValue ?? 0)
        }))
    }
}
