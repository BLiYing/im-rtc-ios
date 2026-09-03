import Foundation

/*
 WebSocket 的最小接口。

 Engine **必须能在无 DOM / 无网络的环境构造**（与 Web 端同一条约束）——
 时序测试全靠注入假连接来跑。所以这里只声明用得到的那几件事，
 生产实现用 `URLSessionWebSocketTask`。
 */

/// 一条 WebSocket 连接。实现方负责把事件回调出来。
public protocol IMWebSocket: AnyObject {
    /// 已经打开、可以发帧。
    var isOpen: Bool { get }
    func send(_ text: String)
    func close(code: Int, reason: String)
    /// resume 开始连接。事件通过 handlers 回来。
    func resume(handlers: IMWebSocketHandlers)
}

/// WebSocket 的事件出口。
public struct IMWebSocketHandlers: Sendable {
    public let onOpen: @Sendable () -> Void
    public let onMessage: @Sendable (String) -> Void
    public let onClose: @Sendable (Int, String) -> Void

    public init(onOpen: @escaping @Sendable () -> Void,
                onMessage: @escaping @Sendable (String) -> Void,
                onClose: @escaping @Sendable (Int, String) -> Void) {
        self.onOpen = onOpen
        self.onMessage = onMessage
        self.onClose = onClose
    }
}

/// 按 URL 造一条连接。测试注入假实现。
public typealias IMWebSocketFactory = @Sendable (URL) -> IMWebSocket

/// 协议约定的 WS 关闭码（§1.5）。
public enum IMCloseCode {
    /// 正常关闭（客户端主动 logout）。不重连。
    public static let normal = 1000
    /// 服务端下线/重启。立即重连。
    public static let goingAway = 1001
    /// 信封非法/帧超长/协议版本不支持。**不重连**，属实现 bug。
    public static let badProtocol = 4400
    /// 未鉴权/鉴权超时/token 无效。换新 token 后重连。
    public static let unauthorized = 4401
    /// 被踢（同 uid 同 device_id 在别处登录）。**不重连**。
    public static let kickedOut = 4403
    /// 频率超限。退避加倍后重连。
    public static let rateLimited = 4429

    /// shouldReconnect 按关闭码判断要不要重连。
    ///
    /// 4400 与 4403 **绝不重连**：前者是我们自己的实现 bug，重连只会再撞一次；
    /// 后者是被踢，重连等于跟另一台设备打架。
    public static func shouldReconnect(_ code: Int) -> Bool {
        code != normal && code != badProtocol && code != kickedOut
    }
}

/// 重连退避：**三端同一份档位**（§1.4）。
///
/// 档位写死成表而不是算指数，是为了四端一眼能对上；抖动是为了避免
/// 「服务端重启后所有客户端在同一毫秒回来」把它再打挂一次。
public enum IMBackoff {
    /// 退避档位（毫秒），之后固定用最后一档。
    public static let stepsMS: [Int] = [1_000, 2_000, 4_000, 8_000, 15_000, 30_000]
    /// 抖动幅度：每档 ±20%。
    public static let jitterRatio = 0.2

    /// delayMS 返回第 attempt 次重连该等多久（attempt 从 0 开始）。
    ///
    /// `random` 可注入以便测试。
    public static func delayMS(attempt: Int, random: () -> Double = { Double.random(in: 0..<1) }) -> Int {
        let index = min(max(attempt, 0), stepsMS.count - 1)
        let base = Double(stepsMS[index])
        let jitter = base * jitterRatio * (random() * 2 - 1)
        return max(0, Int((base + jitter).rounded()))
    }
}

/// URLSession 实现的 WebSocket。
///
/// 读循环是**递归 receive**：`URLSessionWebSocketTask.receive` 一次只回一帧，
/// 不重新挂上去就再也收不到下一帧了——这是这个 API 最常见的用错方式。
final class IMURLSessionWebSocket: NSObject, IMWebSocket, URLSessionWebSocketDelegate {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var handlers: IMWebSocketHandlers?
    private let lock = NSLock()
    private var opened = false
    private var closed = false

    init(url: URL) {
        self.url = url
        super.init()
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return opened && !closed
    }

    func resume(handlers: IMWebSocketHandlers) {
        self.handlers = handlers
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveNext()
    }

    func send(_ text: String) {
        task?.send(.string(text)) { error in
            guard let error else { return }
            IMRTCLog.debug("发帧失败", ["err": error.localizedDescription])
        }
    }

    func close(code: Int, reason: String) {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }

        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.data(using: .utf8))
        // **`finishTasksAndInvalidate` 而不是 `invalidateAndCancel`**：后者会在关闭帧
        // 还没发出去就把连接掐了，服务端只看到 1006 异常断开，于是给这条会话留 30 秒
        // 恢复窗口——用户明明是主动退出的，房里却还挂着他半分钟。
        session?.finishTasksAndInvalidate()
        handlers?.onClose(code, reason)
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                if case let .string(text) = message { self.handlers?.onMessage(text) }
                // **必须重新挂上去**：receive 一次只回一帧。
                self.receiveNext()
            case let .failure(error):
                self.finish(code: IMCloseCode.goingAway, reason: error.localizedDescription)
            }
        }
    }

    private func finish(code: Int, reason: String) {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        guard !alreadyClosed else { return }
        handlers?.onClose(code, reason)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        lock.lock(); opened = true; lock.unlock()
        handlers?.onOpen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        finish(code: closeCode.rawValue, reason: text)
    }
}

/// 生产环境的默认工厂。
public let imURLSessionWebSocketFactory: IMWebSocketFactory = { url in
    IMURLSessionWebSocket(url: url)
}
