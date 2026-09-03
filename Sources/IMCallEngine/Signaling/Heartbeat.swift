import Foundation

/*
 心跳（§1.3）。

 **判活条件是「收到对端任何一帧」，不是「pong 回来了」**——服务端发的任何帧
 都证明它还活着。所以 `noteFrameReceived()` 由读循环无差别调用。

 定时器用 `DispatchSourceTimer` 而不是 `Timer`：后者要挂 RunLoop，
 在后台队列上根本不触发，而这里本来就不在主线程（CONVENTIONS §5）。
 */
final class Heartbeat {
    /// 判死前允许连续静默的周期数（§1.3：3 个周期 = 45 秒）。
    static let missLimit = 3

    private let queue: DispatchQueue
    private let sendPing: () -> Void
    private let onDead: () -> Void
    private var timer: DispatchSourceTimer?
    private var missed = 0

    init(queue: DispatchQueue, sendPing: @escaping () -> Void, onDead: @escaping () -> Void) {
        self.queue = queue
        self.sendPing = sendPing
        self.onDead = onDead
    }

    /// start 按服务端下发的间隔起心跳。重复调用会先停掉旧的。
    func start(intervalSec: Int) {
        stop()
        missed = 0
        let interval = max(1, intervalSec)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    /// noteFrameReceived 由读循环无差别调用：收到任何帧都算对端活着。
    func noteFrameReceived() {
        missed = 0
    }

    /// stop 停掉心跳。幂等。
    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// missedBeats 供测试与诊断观察。
    var missedBeats: Int { missed }

    private func tick() {
        missed += 1
        if missed > Self.missLimit {
            IMRTCLog.warn("心跳超时，判定连接已死", ["missed": String(missed)])
            onDead()
            return
        }
        sendPing()
    }
}
