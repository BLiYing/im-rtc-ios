import Foundation

/*
 会议房的**按页订阅**：把「这个人现在看得见吗」翻译成订阅与退订。

 见 `im-rtc-server/docs/design/MEETING_ROOM_DESIGN.md` §4.3。

 # 为什么挂在 setRemoteLayer 上，而不是新开一个 API

 **Engine 的公开 API 一个都不新增。** Kit 与自画 UI 的宿主本来就得按可视尺寸调
 `setRemoteLayer(uid:layer:)`（九宫格报 `l`、放大报 `h`、看不见报 `none`），
 这套调用已经**完整地表达了「谁在当前页」**。会议房要的只是把同一组调用翻译成另一套帧：
 `l/m/h` = 订阅或换层，`none` = 五秒后退订。新开一个 `subscribePage` 的话，
 宿主要为「会议」写第二套界面代码，而两套之间的差别只有引擎自己知道。

 # 只在 auto_subscribe == "audio" 的房间里生效

 通话房是 `all`：服务端全自动订好，`none` 的语义只是**暂停下发**（协议 §3.5），
 退订会让那个人永远消失。这条分支写错的后果就是通话房里有人的画面再也回不来，
 所以向量里给通话房单列了一组护栏用例（`room_fsm.json` 的
 `call_room_auto_subscribe_all_layer_only`）。
 */
extension IMRoomMachine {
    /**
     翻页离开之后**等多久才真的退订**。

     退订要重协商（sub PC 少一条 m-line），而翻页是来回的动作：左滑一页看一眼再滑回来
     是最常见的操作。立刻退订的话这一来一回要两次协商，回来那一下还得重新等关键帧，
     画面黑一下。等五秒，来回翻的那一种就一次协商都不用。

     定时器不在状态机里（状态机是纯函数，CONVENTIONS §2）：由帧循环按
     ``IMRoomContext/pendingUnsubscribe`` 排，到点喂一个内部事件回来。
     */
    public static let unsubscribeHysteresis: TimeInterval = 5

    /**
     同时订阅的视频路数上限（手机：本页 8 + 迟滞 8）。

     **这个数是 SDP 墙定的，不是算力定的**：sub offer 每订一路多一条 m-line，
     整帧超过 64 KiB 就发不出去，而发不出去的后果是这个人的下行**永久冻结**
     （设计 §1.3）。所以它是硬上限，不是一个可以「先超一点看看」的建议值。
     */
    public static let maxSubscribedVideo = 16

    /// 这个房间的视频是不是由客户端按页订阅的。
    static func usesPagedVideo(_ ctx: IMRoomContext) -> Bool {
        ctx.autoSubscribe == "audio"
    }

    /**
     pagedUpdateLayer 把一次 `setRemoteLayer` 翻译成订阅动作。

     - `none`：**先发 `room.update_layer{none}` 立刻停包**，再排五秒的退订。
       两件事都要：停包省的是带宽（这一下就生效），退订省的是 m-line（五秒后才值得付那次协商）。
     - `l/m/h`：撤掉还没到点的退订；订过就只换层（**不重协商**，这正是迟滞想省下的那一次），
       没订过就订。
     */
    static func pagedUpdateLayer(_ ctx: IMRoomContext, trackID: String,
                                 maxLayer: String) -> IMMachineOutput<IMRoomContext> {
        maxLayer == "none" ? pageOut(ctx, trackID: trackID)
                           : pageIn(ctx, trackID: trackID, maxLayer: maxLayer)
    }

    private static func pageOut(_ ctx: IMRoomContext,
                                trackID: String) -> IMMachineOutput<IMRoomContext> {
        // 没订过的不用退；**正在退的也不用**——那条 `room.unsubscribe` 已经在路上，
        // 再排一次迟滞，五秒后会往一条已经不存在的订阅上再打一发，
        // 而它回来的 1301 会被 dropFailedSubscribe 当成「订阅失败」处理。
        let state = ctx.subscribe[trackID]
        guard state != nil, state != .unsubscribing else { return out(ctx) }
        // 已经排着退订的也不用再报一次 none——它早就不出包了，
        // 再报一次只会把五秒的计时重新拉长。
        guard !ctx.pendingUnsubscribe.contains(trackID) else { return out(ctx) }

        var next = ctx
        next.layers[trackID] = "none"
        next.pendingUnsubscribe.append(trackID)
        return out(next, send: [IMOutgoingFrame(IMFrameType.roomUpdateLayer, [
            "track_id": .string(trackID), "max_layer": .string("none"),
        ])])
    }

    private static func pageIn(_ ctx: IMRoomContext, trackID: String,
                               maxLayer: String) -> IMMachineOutput<IMRoomContext> {
        var next = ctx
        next.pendingUnsubscribe.removeAll { $0 == trackID }

        if next.subscribe[trackID] == .subscribing || next.subscribe[trackID] == .subscribed {
            next.layers[trackID] = maxLayer
            return out(next, send: [IMOutgoingFrame(IMFrameType.roomUpdateLayer, [
                "track_id": .string(trackID), "max_layer": .string(maxLayer),
            ])])
        }

        /*
         **先问腾不腾得出位置，再动手**：本地拒绝要求 `send` 为空、状态不变
         （见 `IMMachineOutput.reject`），所以不能先把强制退订发出去再反悔。

         排着迟滞的那些都还占着 m-line，它们是唯一能腾出来的位置。全退了还满，
         就**只可能是调用方一次要看超过 16 路视频**——翻页翻不出这种局面（一页 8 路），
         那是界面那边的 bug，不该由引擎悄悄吞掉。

         **不排队**：排队要有一个「什么时候轮到你」的触发点，而这里没有——
         订阅位是靠翻页腾出来的，队列只会安静地越积越长，
         表现成「第 17 个人的画面永远不出来，也没有任何报错」。
        */
        guard countLiveVideo(next) - next.pendingUnsubscribe.count < maxSubscribedVideo else {
            return localReject(ctx)
        }

        var send: [IMOutgoingFrame] = []
        freeSlot(&next, send: &send)
        next.subscribe[trackID] = .subscribing
        next.layers[trackID] = maxLayer
        send.append(IMOutgoingFrame(IMFrameType.roomSubscribe, [
            "track_id": .string(trackID), "max_layer": .string(maxLayer),
        ]))
        return out(next, send: send)
    }

    /**
     flushHysteresis 让迟滞到点：把排着的退订真的发出去。

     `trackID` 传 nil 时把**全部**排着的一次清掉（一致性向量用的就是这一种）。
     帧循环按 track 排定时器，所以线上走的是带 trackID 的那一路。

     **通话房什么都不做**：它的 `none` 只是暂停，退订会让那个人的画面再也回不来。

     # 不在 joined 就按兵不动

     断网重连期间这只定时器照样会到点。此时把 `room.unsubscribe` 发出去等于扔进一条死连接：
     它没有 reject 可回（退订帧没有回滚路径），那条 track 会**永远卡在 `unsubscribing`**——
     16 路的账从此少算一路，攒够几次翻页就再也订不上新的人；
     更糟的是它仍占着 sub PC 的 m-line，offer 还在往 64 KiB 上顶。

     留在 ``IMRoomContext/pendingUnsubscribe`` 里不动即可：帧循环每轮按清单对账，
     这一条还在清单上，定时器会**重新排一只**，等房间回到 joined 再退。
     */
    static func flushHysteresis(_ ctx: IMRoomContext,
                                trackID: String?) -> IMMachineOutput<IMRoomContext> {
        guard usesPagedVideo(ctx) else { return out(ctx) }
        guard ctx.state == .joined else { return out(ctx) }
        let targets = trackID.map { id in ctx.pendingUnsubscribe.filter { $0 == id } }
            ?? ctx.pendingUnsubscribe
        guard !targets.isEmpty else { return out(ctx) }

        var next = ctx
        next.pendingUnsubscribe.removeAll { targets.contains($0) }
        var send: [IMOutgoingFrame] = []
        for id in targets { unsubscribeNow(&next, trackID: id, send: &send) }
        return out(next, send: send)
    }

    /**
     dropPending 把已经不存在的 track 从待退订队列里摘掉。

     人走了、对方 unpublish 了，那条订阅本来就没了。不摘的话定时器到点会发一条
     打在空处的 `room.unsubscribe`（服务端幂等，但帧循环会为它多排一轮）。
     */
    static func dropPending(_ ctx: inout IMRoomContext, gone: Set<String>) {
        ctx.pendingUnsubscribe.removeAll { gone.contains($0) }
    }

    private static func unsubscribeNow(_ ctx: inout IMRoomContext, trackID: String,
                                       send: inout [IMOutgoingFrame]) {
        let state = ctx.subscribe[trackID]
        guard state != nil, state != .unsubscribing else { return }
        ctx.subscribe[trackID] = .unsubscribing
        ctx.layers.removeValue(forKey: trackID)
        send.append(IMOutgoingFrame(IMFrameType.roomUnsubscribe, ["track_id": .string(trackID)]))
    }

    /**
     freeSlot 在订满 16 路时**提前**把排着的退订执行掉，腾出位置。

     快速连翻几页就会踩到：第一页还在五秒迟滞里，第二页也翻走了，第三页要订新的。
     迟滞是一种便利，不是承诺——位置不够时先退最早翻走的那一页，正是想退的顺序。
     */
    private static func freeSlot(_ ctx: inout IMRoomContext, send: inout [IMOutgoingFrame]) {
        while countLiveVideo(ctx) >= maxSubscribedVideo, !ctx.pendingUnsubscribe.isEmpty {
            let oldest = ctx.pendingUnsubscribe.removeFirst()
            unsubscribeNow(&ctx, trackID: oldest, send: &send)
        }
    }

    /// countLiveVideo 数此刻**占着 m-line** 的视频路数：订上的与正在订的都算，正在退的不算。
    private static func countLiveVideo(_ ctx: IMRoomContext) -> Int {
        ctx.subscribe.reduce(into: 0) { count, entry in
            guard entry.value != .unsubscribing else { return }
            guard ctx.remoteTracks[entry.key]?.kind == "video" else { return }
            count += 1
        }
    }
}
