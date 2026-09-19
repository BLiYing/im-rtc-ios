import Foundation

/*
 「这一帧没送到」怎么收场。

 从 `IMFrameLoop.swift` 拆出来是体量红线（CONVENTIONS §2，600 行），
 但这一刀本来也该切在这里：主文件管的是**顺利那条路**（发帧、落应答、推状态机），
 这里管的是**每一种不顺利**——被服务端拒了、没等到应答、连接根本不在。
 两者的判断依据完全不同，混在一起读的时候很容易把「被拒」和「没送到」当成一回事，
 而 2026-09-18 真机那次正是栽在这个混淆上（见 `rollback` 里 `room.publish` 那段）。

 `undeliveredExit` 这个存储属性留在主文件（extension 不能有存储属性）。
*/
extension IMFrameLoop {

    /// rollback 把「这一帧没送到」翻译成状态机能收场的内部事件。
    ///
    /// **一张表管住所有中间态**：留在中间态的代价永远是同一种——界面停在一个转圈的屏上，
    /// 而之后每一个动作都被不变量本地拒成 2005，宿主只看到一串没头没尾的 2005，
    /// 真正的原因早淹在上一条 error 里了。四端同一张表
    /// （Android 的 `IMCallEngine.onRequestFailed`、Web 的 `frameLoop.rollback`）。
    func rollback(_ frame: IMOutgoingFrame, _ error: IMRTCError) async {
        let type = frame.type
        /*
         **进房失败要把房间状态退回 idle**。

         不退的话状态机永远停在 `joining`，之后每一次 publish 都会被不变量 R1
         本地拒成 2005，而宿主只看到两条没头没尾的 2005——真正的原因
         （那条 room.join 被服务端拒了）已经淹在上一条 error 里了。
         退回 idle 至少让「重进一次」成为可能。
         */
        if type == IMFrameType.roomJoin {
            await dispatch(.internalEvent(name: "join_failed"))
        }
        /*
         **离房被拒也要退回 idle**，这是 join_failed 的镜像，漏掉它的代价更大。

         `room.leave` 会被拒是真事：服务端在「会话已不在房间里」时回 1203
         （两人同时离房、或房间刚被「已空，已关闭」销毁掉，都撞得上）。
         而被拒的语义恰恰是**我们已经不在房里了**，本地却还停在 leaving：
         `leaveCallbacks` 一个都不会抛，于是 `media.close()` 永远不调用
         （摄像头、麦克风一直开着），再点离房被 R1 拒成 2005，
         再 join 也因为「不在 idle」被拒——除非 logout，这台 Engine 永远进不了房。
         （Android 的 `IMCallEngine.onRequestFailed` 一直接着这一条。）
        */
        if type == IMFrameType.roomLeave {
            await dispatch(.internalEvent(name: "leave_failed"))
            /*
             等应答期间断线的话，房间机先收到 `disconnected` 从 `leaving` 进了 `reconnecting`，
             `leave_failed` 就不认了——恢复之后人又回到房里，而宿主早就按了离开。
             这一帧只可能是宿主要离房才发的，没有通话时照样本地收场（ACTION_RESULT_DESIGN D2）。
             */
            if ctx.call.state == .idle { await endLocally() }
            return
        }
        /*
         **退出类被拒也要本地收场**（ACTION_RESULT_DESIGN D2）：用户按的是「结束」，服务端拒了
         （最常见的是通话已经结束 1402 / 1401）或根本没发出去，都不该让界面停在通话里。
         结束帧已经试过了，这里只落本地——与 `forceEnd` 同一份收场计算，只是不再发帧。
         */
        if IMCallExit.allFrameTypes.contains(type) {
            /*
             **没送到的结束帧要记下来，重连之后补发（2026-09-18 加）。**

             本地收场是对的——用户按了「结束」，界面必须收起来。但**服务端那边没收到**：
             它只当我们掉线了，把我们留在恢复窗口里；窗口内一重连，成员关系又被「取消离房」
             恢复过来，于是房里挂着一个界面上早已挂断的人。真机 18:18:47
             `不等应答的请求失败了 type=call.hangup code=2003`，一秒后
             `会话已恢复 → 在恢复窗口内重连，取消离房`，对端对着这个幽灵坐了 3 分钟
             才手动挂断。

             只记「没等到应答」的那几种（`unansweredCodes`）：服务端真回了拒绝
             （通话已结束 1401/1402）说明它那边本来就没这通，补发只会换回同一个拒绝。
            */
            if Self.unansweredCodes.contains(error.code) {
                undeliveredExit = frame
                IMRTCLog.warn("结束帧没送到，记下待重连补发", [
                    "type": type, "call_id": ctx.call.callID, "code": String(error.code.rawValue),
                ])
            }
            await endLocally()
            return
        }
        /*
         同理，**通话类请求被拒也要退回 idle**。不退的话界面停在「正在呼叫…」，
         而服务端根本没有这通电话，之后每次挂断都换回 1401 call_not_found，
         用户永远退不出那一屏。

         **三帧都要接，不只是 invite。** `call.accept` 被拒（主叫刚取消，
         服务端回 1401/1405）时通话机永久停在 `accepting`：onCallEnd 不抛、
         来电页收不起来，而那时红按钮算出来的是 reject，
         `reduceAct("reject")` 又要求 `ringing`——只换回又一个 2005，
         用户除了杀进程出不去。`call.join` 同理。
         （Android 的 onRequestFailed 一直是 INVITE / ACCEPT / JOIN 三个一起接的。）
        */
        if Self.callFailFrames.contains(type) {
            await dispatch(.internalEvent(name: "call_failed"))
        }
        /*
         **发布被拒：通话里直接收掉整通（reason=error），没有通话才只回滚那一条**（静默失败审计 §A）。

         原先这张表不认 `room.publish`，那条轨道永远停在 `publishing`：`publish.ok` 不来 →
         pub offer 永远不产出 → 上行从未协商。界面显示已接通、计时器在走、按钮显示没静音，
         **对方全程听不见看不见，零提示**。留在通话里只报错也不够——Kit 并不展示这类错误，
         而服务端会拒的几种情形（房间已不在、同一路重复发布）重试都救不回来。
         收场走 forceEnd：挂断帧不排队、onCallEnd 只抛一次，Kit 本来就认它（Web 端同一份推理：`frameLoop.ts`）。

         **但「没等到应答」不算被拒（2026-09-18 改）。** 原先这段把请求超时也算进
         「重试救不回来」里，真机打了脸：18:18:39 `room.publish` 超时、整通被收成
         `reason=error`，而 **9 秒后连接就回来、会话也在恢复窗口内 resume 成功了**。
         超时不是答复，只说明这一问没送到；挂起来等重连即可（见 `deferPublish`）。
         真连不回来的话 `SignalConnection+ResumeGiveUp` 那条 80 秒倒计时照样收场，
         不需要这里抢着下手。

         **会议房同理**（没有通话、只在房里）：原先这一支只对通话开放，会议房的超时落到
         `publish_failed`，这一路被悄悄摘掉、不重试、不通知宿主——信令抖一下用户就静音或黑屏。
         恢复窗口的倒计时是连接层的，不分通话与会议；真恢复不了时 `dropLostSession` 照样补 onRoomLeft。
         */
        if type == IMFrameType.roomPublish {
            if Self.unansweredCodes.contains(error.code) {
                IMRTCLog.warn("发布没等到应答，挂起等重连", [
                    "call_id": ctx.call.callID, "code": String(error.code.rawValue),
                ])
                await dispatch(.internalEvent(name: "publish_deferred", args: frame.data))
                return
            }
            if ctx.call.state != .idle {
                IMRTCLog.warn("发布被拒，结束本端通话", [
                    "call_id": ctx.call.callID, "code": String(error.code.rawValue),
                ])
                await forceEndForPublishFailure()
                return
            }
            await dispatch(.internalEvent(name: "publish_failed", args: ["cid": frame.data["cid"] ?? .string("")]))
            return
        }
        // 订阅被拒只摘记账，不收场：最常见的 1301 是订阅与对方停推赛跑输了，通话本身没事。
        if type == IMFrameType.roomSubscribe {
            await dispatch(.internalEvent(name: "subscribe_failed",
                                          args: ["track_id": frame.data["track_id"] ?? .string("")]))
        }
    }

    /**
     forceEndForPublishFailure 是 `room.publish` 在通话里被拒时的收场路径。

     与门面的 `IMCallEngine.forceEnd()` 同一个形状（结束帧直发、本地立刻收场），但**不经过
     mirror 也不需要 call_id/room_id 比对**——这里已经在 actor 内部，`ctx` 就是此刻的真实状态，
     没有跨 actor 的那一拍延迟。`reason` 写死 `.error`：这不是用户按的红键，写成 hangup 是撒谎。
     */
    func forceEndForPublishFailure() async {
        let ended = IMEngineMachine.forceEnd(ctx, reason: .error)
        guard !ended.emit.isEmpty else { return }
        if let connection = connection() {
            for frame in ended.send {
                connection.fire(frame.type, data: IMFrameSender.wireData(frame) ?? frame.data)
            }
        } else if !ended.send.isEmpty {
            IMRTCLog.warn("发布被拒收场：没有信令连接，结束帧发不出去，只做本地收场", [:])
        }
        await apply(IMMachineOutput(ended.state, send: [], emit: ended.emit), settlement: nil)
    }

    /// endLocally 按此刻状态本地收场（通话或会议），不发帧。已经收干净时什么都不做。
    func endLocally() async {
        let ended = IMEngineMachine.forceEnd(ctx)
        guard !ended.emit.isEmpty else { return }
        IMRTCLog.warn("结束帧失败，本地收场", ["call_id": ctx.call.callID, "room_id": ctx.room.roomID])
        await apply(IMMachineOutput(ended.state, send: [], emit: ended.emit), settlement: nil)
    }

    /// callFailFrames 是「这一帧被拒 = 这通电话没建立起来」的那几帧。
    ///
    /// 少接一帧的后果都一样：通话机停在中间态，界面收不起来，
    /// 而红按钮在那个状态下算出的动作又会被本地拒成 2005。
    private static let callFailFrames: Set<String> = [
        IMFrameType.callInvite, IMFrameType.callAccept, IMFrameType.callJoin,
    ]

    /// unansweredCodes 是「这一问没能送到 / 没等到回话」的那几个码——**不是服务端的答复**。
    ///
    /// 与它们相对的是服务端真回了一个 `err`（1xxx）：那才叫被拒，重试救不回来。
    /// 这三个都只说明本端与服务端此刻不通，而连接回来之后同一问多半就成了，
    /// 所以发布走 `publish_deferred` 挂起等重连，而不是把整通电话收掉（见 `rollback`）。
    private static let unansweredCodes: Set<IMErrorCode> = [
        .signalingTimeout, .networkUnreachable, .notLoggedIn,
    ]
}
