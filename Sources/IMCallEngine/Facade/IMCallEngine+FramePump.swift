import Foundation

/**
 帧泵：**下行的东西进状态机的唯一入口**。

 从门面拆出来是因为体量红线（CONVENTIONS §2，600 行），
 但这一刀本来也该切在这里——门面管的是「对宿主的那张 API 表」，
 这里管的是「线路上的东西怎么按顺序变成状态机的输入」，两件事。

 为什么必须串行、以及为什么连 `sys.hello.ok` 都要一起排队，见 ``IMLoopWork``
 与 `IMCallEngine.frameInlet`。
 */
extension IMCallEngine {

    /// startFramePump 起一条串行泵，返回它的入口。见 `frameInlet` 的说明。
    ///
    /// `AsyncStream` 用旧式 init 而不是 `makeStream`：后者要 iOS 16，本仓最低 15。
    /// 缓冲策略是默认的 unbounded——**信令帧一帧都不能丢**。
    func startFramePump() -> AsyncStream<IMLoopWork>.Continuation {
        stopFramePump()
        var inlet: AsyncStream<IMLoopWork>.Continuation!
        let stream = AsyncStream<IMLoopWork> { inlet = $0 }
        let continuation = inlet!
        stateQueue.sync { self.frameInlet = continuation }
        let pump = Task { [weak self] in
            for await work in stream {
                guard let self else { return }
                await self.consume(work)
            }
        }
        stateQueue.sync { self.framePump = pump }
        return continuation
    }

    /// stopFramePump 关掉泵。`finish()` 之后 `for await` 会自然结束。
    func stopFramePump() {
        let (inlet, pump) = stateQueue.sync { () -> (AsyncStream<IMLoopWork>.Continuation?, Task<Void, Never>?) in
            let pair = (frameInlet, framePump)
            frameInlet = nil
            framePump = nil
            return pair
        }
        inlet?.finish()
        _ = pump
    }

    /// consume 按顺序把一件事喂给状态机。**泵里唯一的消费者**，所以顺序就是入队顺序。
    func consume(_ work: IMLoopWork) async {
        switch work {
        case let .frame(type, data):
            await loop.handleIncoming(type, data)

        case let .connected(sessionID, resumed):
            await loop.dispatch(.recv(type: IMEnvelope.okType(IMFrameType.hello), data: [
                "session_id": .string(sessionID),
                "resumed": .bool(resumed),
            ]))
            /*
             协议 §1.4：恢复之后媒体面要重新协商。服务端那侧主动下发
             `room.offer{pc:"sub"}`，而 `pub` 这条的 offerer 是本端，只能自己重发。

             **这一条不能只挂在「PC 判 failed 的那一刻」**——网一断信令也跟着断，
             房间立刻变成 `reconnecting`，而 PC 要等约 30 秒才判 `failed`：那时
             `restart_pub_ice` 会被状态机以 `invalid_state` 拒掉，而它**不进
             bufferedOps**，于是永远丢失。真机 2026-09-07 抓到的正是这一幕
             （`动作被状态机本地拒绝 op=restart_pub_ice room_state=reconnecting`），
             ICE 自愈在它唯一该生效的场景里等于不存在。

             **不查 PC 当前状态、无条件重启**：换了连接就等于换了网络路径，
             旧候选多半已废；服务端那侧也是无条件重启 `sub`，两边对称。
             代价是一次多余的协商，比漏掉一次自愈便宜得多。
             房间不在 joined 时状态机自会拒掉，不必在这里判。
            */
            guard resumed else { return }
            IMRTCLog.info("会话已恢复，重新协商上行", [:])
            media?.restartPubICE()
            await loop.dispatch(.act(op: "restart_pub_ice"))

        case .disconnected:
            await loop.dispatch(.internalEvent(name: "disconnected"))

        case .kickedOut:
            // 状态机只认「被踢了」这一件事；原因是给宿主做处置判断的，两者分开走
            // （IMFrameLoop 里刻意不外发状态机那份 onKickedOut）。
            await loop.dispatch(.internalEvent(name: "ws_closed_4403"))
        }
    }
}
