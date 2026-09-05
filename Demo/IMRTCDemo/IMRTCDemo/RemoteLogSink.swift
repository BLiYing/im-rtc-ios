import Foundation
import UIKit
import IMCallEngine

/*
 把 Engine 的日志送回服务端落盘（仅开发）。

 # 为什么需要

 真机上的日志只活在 Xcode 控制台里——而真机联调时 Xcode 常常根本没连着。
 要分析一次问题就得复制粘贴，跟服务端、跟另一端的浏览器对不上时间轴。
 送回服务端之后，一次通话的**两端加服务端**能按时间轴放在一起读
 （`im-rtc-server/scripts/timeline.py`，它认 `client-ios-*.log`）。

 # 边界

 这是 **Demo 的东西，不是 SDK 的**。SDK 只提供 `IMRTCLog.setSink` 这个接缝；
 「日志送到哪里去」永远是宿主的决定。服务端那个接收口也只在 `-demo-login` 下存在。
 */
final class RemoteLogSink: IMRTCLogSink, @unchecked Sendable {

    private struct Entry: Encodable {
        let at_ms: Int64
        let level: String
        let msg: String
        let fields: [String: String]
    }

    private let endpoint: URL
    private let client: String
    private var queue: [Entry] = []
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var flushing = false

    /// 攒批间隔 1 秒；队列上限 500，满了丢**最旧**的：正在排查的问题总在最近这几条里。
    private let maxQueue = 500
    /// 服务端单次最多收 200 条（handlers_devlog.go 的 devLogMaxEntries）。
    private let batchSize = 200

    init(server: String, client: String) {
        self.endpoint = URL(string: "\(server)/v1/dev/logs")!
        self.client = client
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer
        timer.resume()
        // 切后台时最后一批往往正是最要紧的那批（比如崩溃前那几条）。
        NotificationCenter.default.addObserver(
            self, selector: #selector(onBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func onBackground() { flush() }

    /// write 记一条。**绝不能抛、绝不能阻塞**——日志失败不该影响通话。
    func write(level: IMRTCLogLevel, message: String, fields: [String: String]) {
        let entry = Entry(at_ms: Int64(Date().timeIntervalSince1970 * 1000),
                          level: Self.levelName(level), msg: message, fields: fields)
        lock.lock()
        queue.append(entry)
        if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        guard !flushing, !queue.isEmpty else { lock.unlock(); return }
        flushing = true
        let batch = Array(queue.prefix(batchSize))
        queue.removeFirst(batch.count)
        lock.unlock()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // **必须设超时**：默认 60 秒，而 flushing 这个闩要等回调才放开——
        // 一个卡住的请求就能让**后面所有日志静默丢掉**，而且完全看不出来
        // （实测踩过：日志文件停在某个时间点不动，应用其实还活着）。
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Payload(client: client, entries: batch))

        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            // 发失败就算了：**不重试、不回队**。日志是尽力而为的，重试只会把队列撑爆。
            self?.lock.lock(); self?.flushing = false; self?.lock.unlock()
        }.resume()
    }

    private struct Payload: Encodable {
        let client: String
        let entries: [Entry]
    }

    private static func levelName(_ level: IMRTCLogLevel) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        case .off: return "OFF" // 到不了这里：off 级别的消息根本不会进 sink
        }
    }
}
