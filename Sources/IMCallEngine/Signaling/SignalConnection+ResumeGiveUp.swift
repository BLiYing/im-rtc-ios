import Foundation

/*
 「断开太久，服务端那一侧的会话已经不可能再恢复」的判定（协议 §1.4）。
 从 `SignalConnection.swift` 拆出来（体量红线，CONVENTIONS §2）：一个类型的不同关注点拆 extension。
 撤倒计时的两处（握手成功、`close()`）留在原文件，与各自的状态变更写在一起。
 */

extension IMSignalConnection {
    /// 协议 §1.4 的恢复窗口：30 秒。**四端同一个值**，服务端的 `ResumeWindow` 也是它。
    static let resumeWindowSec = 30
    /// 服务端判一条连接死掉要连续几个心跳周期收不到东西（§1.3）。
    static let serverDeathPings = 3
    /// 余量：跨过服务端窗口到期那一刻再收场，别跟它抢同一秒。
    static let giveUpGraceSec = 5

    /*
     断开多久之后可以断定「服务端那一侧的会话没了」。

     # 为什么不是恢复窗口那 30 秒

     服务端的 30 秒**不是从我们断开的那一刻算起的**，是从**它自己察觉**的那一刻算起。
     而它靠读超时察觉：连续 3 个心跳周期收不到任何东西才判死（§1.3）。
     我们断开时距离上一帧最多一个心跳周期，所以最晚的到期时刻是
     `断开 + 3×ping + 30s`——按默认 15 秒心跳就是 45 + 30 = 75 秒，再加一点余量。

     # 为什么必须取上界

     取短了就会撒谎：真机 2026-09-08 那通，断开 14 秒后重连**成功恢复**，通话好端端地继续。
     在那之前宣布「通话已结束」是把一通还能救回来的电话杀掉，而且服务端还认为我们在房里，
     房间会挂着一个幽灵成员。**宁可让用户多看几十秒「正在重连」，也不能提前下结论。**
     */
    var giveUpDelayMS: Int {
        if let override = options.resumeGiveUpDelayMSForTesting { return override }
        return (Self.serverDeathPings * pingIntervalSec + Self.resumeWindowSec + Self.giveUpGraceSec) * 1000
    }

    /**
     起「服务端已经彻底放弃」的倒计时。

     **只在第一次断开时起**：每一次重连失败都会走到这里，每次都重排的话截止时刻
     就一直往后挪、永远不会到——而那正是它要治的病。起点是第一次断开的那一刻，
     与服务端算的是同一笔账。
     */
    func armUnrecoverableTimer() {
        guard unrecoverableTimer == nil else { return }
        let delay = giveUpDelayMS
        IMRTCLog.info("恢复窗口倒计时已起", ["delay_ms": String(delay)])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(delay))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.unrecoverableTimer = nil
            // 服务端已经丢掉这个会话，再拿它去要 resume 只会白跑一趟。
            self.sessionID = ""
            IMRTCLog.warn("断开已超过恢复窗口，会话不可恢复")
            self.events.onSessionUnrecoverable?()
        }
        unrecoverableTimer = timer
        timer.resume()
    }
}
