import Foundation

/**
 卡顿探针：盯着几条「本该随叫随到」的执行通道，谁排不上号就记一笔。

 # 为什么要有它

 2026-09-13 14:53 frank：`call.connected` 到了，`room.join` 却晚了 28.6 秒才上线路，
 麦克风一直没推上去，挂断一帧没发出去。事后日志里**看不出卡在哪**——主线程、
 Swift 并发线程池、帧循环 actor 都有可能，而现场已经没了，只能等人连着 Xcode 再撞一次。

 这个探针每隔一小段往每条通道各投一枚空任务，超过阈值还没被执行就记一条 WARN，
 恢复时再记一条实际卡了多久。下次再出同样的事，**不连 Xcode 也知道是哪一条堵了**。

 # 通道

 由门面注入（见 `IMCallEngine.stallProbe`）：
 - `main`：主线程——界面、Kit 的全部回调；
 - `concurrency_pool`：Swift 并发的全局执行器——每个 `Task`、每个非隔离的 async 函数都跑在这；
 - `frame_loop`：帧循环 actor——状态机、发帧都要进它。
   pool 通而 frame_loop 堵，说明 actor 里有同步阻塞；两个一起堵，说明线程池被占满了。

 # 探针自己被挂起的那一段不算

 切后台、调试器暂停时整个进程都停了，探针的定时器也一样。醒来那一刻量出来的
 「卡了几十秒」不是哪条通道的锅，所以两次 tick 隔得太久就把测量清零重来。
 */
final class IMStallProbe: @unchecked Sendable {
    /// 往某条通道投一枚空任务；任务真跑起来时调用 `done`。
    typealias Launch = @Sendable (_ done: @escaping @Sendable () -> Void) -> Void
    /// 记一条：`stalled` 为真是卡住了，为假是恢复了。
    typealias Report = @Sendable (_ stalled: Bool, _ message: String, _ fields: [String: String]) -> Void

    struct Lane {
        let name: String
        let launch: Launch
    }

    private let lanes: [Lane]
    private let thresholdMS: UInt64
    private let intervalMS: Int
    private let nowMS: @Sendable () -> UInt64
    private let report: Report

    // 以下全部归 `queue`。
    private let queue = DispatchQueue(label: "com.imrtc.engine.stallprobe")
    private var timer: DispatchSourceTimer?
    private var pendingSince: [UInt64?]
    private var reported: [Bool]
    private var lastTickMS: UInt64 = 0
    /// 每次清零 +1：上一轮投出去、很久之后才回来的探针认得出自己已经作废。
    private var generation = 0

    init(lanes: [Lane],
         thresholdMS: UInt64 = 1_500,
         intervalMS: Int = 500,
         nowMS: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
         report: @escaping Report = { stalled, message, fields in
             if stalled { IMRTCLog.warn(message, fields) } else { IMRTCLog.info(message, fields) }
         }) {
        self.lanes = lanes
        self.thresholdMS = thresholdMS
        self.intervalMS = intervalMS
        self.nowMS = nowMS
        self.report = report
        pendingSince = Array(repeating: nil, count: lanes.count)
        reported = Array(repeating: false, count: lanes.count)
    }

    deinit {
        timer?.cancel()
    }

    /// start 开始盯。重复调用无害。
    func start() {
        queue.async {
            guard self.timer == nil else { return }
            self.resetMeasurements()
            self.lastTickMS = 0
            self.timer = imEvery(.milliseconds(self.intervalMS), on: self.queue) { [weak self] in self?.tick() }
        }
    }

    /// stop 停下。**logout 必须调**（CONVENTIONS §7：Engine 释放后不许留着循环）。
    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.resetMeasurements()
        }
    }

    /// 测试用：同步走一轮。
    func tickNow() { queue.sync { tick() } }

    /// 测试用：等已经排进队列的回执落地。
    func drain() { queue.sync {} }

    private func tick() {
        let now = nowMS()
        if lastTickMS != 0, now - lastTickMS > UInt64(intervalMS) * 4 {
            resetMeasurements()
        }
        lastTickMS = now
        for index in lanes.indices {
            check(index, now: now)
        }
    }

    private func check(_ index: Int, now: UInt64) {
        guard let since = pendingSince[index] else {
            launch(index, now: now)
            return
        }
        let waited = now - since
        guard !reported[index], waited >= thresholdMS else { return }
        reported[index] = true
        report(true, "执行通道卡顿", ["lane": lanes[index].name, "waited_ms": String(waited)])
    }

    private func launch(_ index: Int, now: UInt64) {
        pendingSince[index] = now
        let token = generation
        lanes[index].launch { [weak self] in
            guard let self else { return }
            self.queue.async { self.finish(index, token: token) }
        }
    }

    private func finish(_ index: Int, token: Int) {
        guard token == generation, let since = pendingSince[index] else { return }
        if reported[index] {
            report(false, "执行通道卡顿恢复",
                   ["lane": lanes[index].name, "stalled_ms": String(nowMS() - since)])
        }
        pendingSince[index] = nil
        reported[index] = false
    }

    private func resetMeasurements() {
        generation += 1
        pendingSince = Array(repeating: nil, count: lanes.count)
        reported = Array(repeating: false, count: lanes.count)
    }
}
