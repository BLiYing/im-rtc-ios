import Foundation

extension IMCallEngine {

    /**
     forceEnd 强制结束当前这一场：**结束帧立刻上线路，本地立刻收场，不等服务端。**

     给「红键按下去、等不到结束事件」用——Kit 的看门狗到点就调它。宿主自画 UI 时同理：
     `hangup()` 发出去几秒没收到 `onCallEnd`，就调这个。可以在任何线程调用，不会阻塞。

     # 与 hangup 的区别

     `hangup()` 只发帧，状态由服务端的 `call.ended` 推进（§5.1）。帧没发出去或被拒了，
     这一场就收不掉。`forceEnd()` 不等：

     1. 按此刻的状态挑结束帧（通话中 hangup、响铃中 reject、会议里 room.leave，见
        `IMEngineMachine.endFrames`），**同步交给信令连接的串行队列**。不经过帧循环，
        也不需要在 Swift 并发里排上号——2026-09-13 14:54 frank 那次，正常路径上的
        room.join 晚了 28.6 秒、call.hangup 一帧都没到服务端，卡的正是那一段
        （原因还没定位，下次再出现由 `IMStallProbe` 记下是哪条通道堵了）。
     2. 本地收场：通话机、房间机归零，关媒体，抛 `onCallEnd`（会议抛 `onRoomLeft`）。
        服务端随后的 `call.ended` 会因为本地已是 idle 被静默丢弃，不会抛第二次。

     # 收场之后才到的东西

     卡在路上的 room.join 可能比 call.hangup **更晚**到服务端，而服务端照样放人进房
     （它只验房票，不查通话成员）。本端收到那条迟到的 `room.join.ok` 会补发 `room.leave`
     （`IMRoomMachine.reduceRecv` 的 idle 分支）；迟到的候选、SDP 也不会把 PC 重新建起来
     （`IMFrameLoop.handleIncoming`）。

     拨出时 `call.invite.ok` 还没回来就强制收场：此刻手里没有 call_id，发不了 cancel。
     等那条 invite.ok 回来，通话机的 idle 分支补发 `call.cancel`；要是被叫抢先接了、
     回来的是 `call.connected`，就补发 `call.hangup`（`IMCallMachine.handleLateFrame`）。

     # 已知限制

     - 连接断着时帧发不出去，只做本地收场；服务端那边由恢复窗口到期兜底。
     */
    @objc public func forceEnd() {
        let snapshot = loop.mirror.value
        let plan = IMEngineMachine.forceEnd(snapshot)
        guard !plan.emit.isEmpty else {
            IMRTCLog.info("强制收场：没有进行中的通话或房间", [:])
            return
        }
        IMRTCLog.warn("强制收场", [
            "call_id": snapshot.call.callID,
            "call_state": snapshot.call.state.rawValue,
            "room_id": snapshot.room.roomID,
            "room_state": snapshot.room.state.rawValue,
            "frames": plan.send.map(\.type).joined(separator: ","),
        ])
        if let connection = currentConnection {
            for frame in plan.send {
                connection.fire(frame.type, data: IMFrameSender.wireData(frame) ?? frame.data)
            }
        } else if !plan.send.isEmpty {
            IMRTCLog.warn("强制收场：没有信令连接，结束帧发不出去，只做本地收场", [:])
        }
        let callID = snapshot.call.callID
        let roomID = snapshot.room.roomID
        Task { [loop] in await loop.forceEnd(callID: callID, roomID: roomID) }
    }
}
