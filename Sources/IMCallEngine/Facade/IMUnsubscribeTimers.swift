import Foundation

/**
 IMUnsubscribeTimers 是翻页退订那五秒迟滞的**定时器那一半**。

 # 为什么定时器不在状态机里

 状态机是纯函数（CONVENTIONS §2），所以它只记下「这几条等着退订」
 （``IMRoomContext/pendingUnsubscribe``），到点该做什么由它自己在收到内部事件时决定。
 这里负责把那份清单**变成真的定时器**。

 # 为什么是「对账」而不是「排一次」

 排队的来路不止一条：翻页报 `none` 会加一条，翻回来会撤一条，人走了 / 对方关摄像头
 会让它凭空消失，订满 16 路时还会被提前强制退掉。让每一条来路各自记得排 / 撤定时器，
 总有一条会漏——漏掉撤销的表现是**翻回来看着的人五秒后突然没了画面**。
 所以这里每次状态推进后按清单**整体对账**：清单里有而没定时器的排上，
 有定时器而清单里没有的撤掉。来路再多也不用改这里。

 **只在 `IMFrameLoop` 这个 actor 里用**，所以自己不加锁。
 */
final class IMUnsubscribeTimers {
    private var timers: [String: DispatchSourceTimer] = [:]
    private let queue: DispatchQueue
    private let onElapsed: @Sendable (String) -> Void

    init(queue: DispatchQueue, onElapsed: @escaping @Sendable (String) -> Void) {
        self.queue = queue
        self.onElapsed = onElapsed
    }

    deinit { for (_, timer) in timers { timer.cancel() } }

    /// sync 让定时器与待退订清单一致。每次状态推进后调一次。
    func sync(_ pending: [String]) {
        let wanted = Set(pending)
        for (trackID, timer) in timers where !wanted.contains(trackID) {
            timer.cancel()
            timers.removeValue(forKey: trackID)
        }
        for trackID in wanted where timers[trackID] == nil {
            let fire = onElapsed
            timers[trackID] = imAfter(IMRoomMachine.unsubscribeHysteresis, on: queue) {
                fire(trackID)
            }
        }
    }

    /// clear 撤掉全部定时器（离房、logout）。
    func clear() {
        for (_, timer) in timers { timer.cancel() }
        timers.removeAll()
    }

    /// armed 是此刻挂着几只，供测试断言「撤销真的做了」。
    var armed: Int { timers.count }
}
