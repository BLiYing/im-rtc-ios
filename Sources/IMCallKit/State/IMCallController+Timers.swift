import Foundation
import IMCallEngine

/*
 界面上会「过几秒自己走」的三只表：红键看门狗、提示自动撤、邀请占位格终局后停 2s 再收。

 从 `IMCallController.swift` 拆出来（体量红线，CONVENTIONS §2）。计时器本身仍由 controller 持有，
 `deinit` 与 `onStateChanged` 里的取消逻辑留在原处——**持有方释放时必须 cancel** 那条规矩只认一个地方。
 */

extension IMCallController {
    /**
     红键的看门狗：按下 `IMEndWatchdogSeconds` 之后这一屏还在原地，就**本地收场**。

     为什么需要它：2026-09-09 在 Android 上复现——摄像头权限设成「每次询问」时权限门在
     拨出中途没落定，`call.invite` **一帧没发**，而界面早已切成 outgoing。红键映射到
     `cancel`，引擎的通话状态机却还在 Idle，于是**本地拒成 2005、一帧不发、
     也没有任何结束事件回来**，界面永远停在「正在呼叫…」。

     iOS 这一侧同形：`placeCall` 也是先 `apply(.callPlaced)` 再过权限门，而
     `imEndAction` 连 Android 那条 `Action.none` 兜底都没有（`default` 直接给 `hangup`）。
     判据因此只能是**「按下之后这一屏到底走没走」**——用户按红键时的意图没有歧义：
     把我弄出去；这条路必须在本地就能走完，不许依赖服务端应答。
     */
    func armEndWatchdog(reason: String) {
        endWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + IMEndWatchdogSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.endWatchdog = nil
            guard self.state.phase != .idle, self.state.phase != .ended else { return }
            IMRTCLog.warn("[Kit] 红按钮本地收场：没等到结束事件",
                          ["phase": String(describing: self.state.phase)])
            self.apply(.callEnd(reason: reason, durationSec: 0))
            /*
             **界面收了，Engine 也要收。** 只收界面的话，结束帧没发出去时 Engine 还留在通话与房间里：
             服务端照样当他在场，别人一直看得见他，摄像头麦克风也还开着
             （2026-09-13 14:54 frank，直到 14:58 整通结束才被带走）。
             `forceEnd` 不走帧循环，直接把结束帧交给信令连接，并在本地收场。
            */
            self.engine.forceEnd()
        }
        endWatchdog = timer
        timer.resume()
    }

    /**
     提示（「通话已满员」「对方已拒接」）**停几秒就撤**。

     `statusLine` 里 hint 优先于时长，不撤的话「通话已满员」会顶着标题栏直到通话结束，
     计时器再也不出现（规范 §08：这些是 toast，不是常驻状态）。
     */
    func scheduleHintExpiry(from before: IMCallViewState) {
        guard state.hint != before.hint else { return }
        hintTimer?.cancel()
        hintTimer = nil
        guard !state.hint.isEmpty else { return }
        let shown = state.hint
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + IMHintHoldSeconds)
        timer.setEventHandler { [weak self] in
            // 只清掉自己那条：中途又来一条新提示时，不该被上一条的计时器抹掉。
            guard let self, self.state.hint == shown else { return }
            self.apply(.hint(""))
        }
        hintTimer = timer
        timer.resume()
    }

    /// 邀请中的格子拿到终局（已拒绝 / 未接听）后停 2s 再收（交互稿 §05 G3）。
    func scheduleSettledRemovals() {
        for p in state.participants where p.settled != .none && settleTimers[p.uid] == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + IMSettledHoldSeconds)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.settleTimers[p.uid] = nil
                // 停的这 2 秒里又被重新邀请（userRinging 清掉了终局）：不收。
                if self.state.participants.contains(where: { $0.uid == p.uid && $0.settled != .none }) { self.apply(.userRemove(uid: p.uid)) }
            }
            settleTimers[p.uid] = timer
            timer.resume()
        }
    }
}
