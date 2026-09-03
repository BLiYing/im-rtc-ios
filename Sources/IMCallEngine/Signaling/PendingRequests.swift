import Foundation

/*
 在途请求表：**按 `req_id` 配对，不按帧类型**。

 pub 侧的 `room.offer` 是由 **`room.answer`** 应答的（§3.3 固定 offerer），
 只看类型对不上号；按 req_id 配对还顺带解决了「多个同类请求在途」的问题。

 所有方法都必须在**同一条串行队列**上调用（由 SignalConnection 持有），
 所以这里没有锁——加锁反而会掩盖「谁在哪条线程上调它」这件事。
 */

/// 一次请求的应答。
public struct IMRequestResult: Sendable {
    public let envelope: IMEnvelope
    /// 已按帧声明补齐默认值的 data（线路形状）。
    public let data: [String: IMJSON]
}

final class PendingRequests {
    private struct Waiter {
        let type: String
        let timer: DispatchSourceTimer
        let complete: (Result<IMRequestResult, IMRTCError>) -> Void
    }

    private let queue: DispatchQueue
    private let timeoutMS: Int
    private var waiters: [String: Waiter] = [:]

    init(queue: DispatchQueue, timeoutMS: Int) {
        self.queue = queue
        self.timeoutMS = timeoutMS
    }

    /// track 登记一个在途请求。超时会以 `signalingTimeout` 结算。
    func track(reqID: String, type: String,
               complete: @escaping (Result<IMRequestResult, IMRTCError>) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(timeoutMS))
        timer.setEventHandler { [weak self] in
            guard let self, let waiter = self.waiters.removeValue(forKey: reqID) else { return }
            waiter.timer.cancel()
            waiter.complete(.failure(IMRTCError(.signalingTimeout, "\(type) 等应答超时")))
        }
        waiters[reqID] = Waiter(type: type, timer: timer, complete: complete)
        timer.resume()
    }

    /// abandon 撤掉一个还没发出去就失败的请求。
    func abandon(reqID: String) {
        guard let waiter = waiters.removeValue(forKey: reqID) else { return }
        waiter.timer.cancel()
    }

    /// settle 用一帧应答结算在途请求。
    ///
    /// 返回 false 表示这个 req_id 没人在等——调用方应当把它当事件处理。
    func settle(_ envelope: IMEnvelope, decode: (IMEnvelope) -> [String: IMJSON]) -> Bool {
        guard let waiter = waiters.removeValue(forKey: envelope.reqID) else { return false }
        waiter.timer.cancel()

        // sys.error 也是应答：**它带着 req_id 回来**，要结算成失败而不是当事件抛。
        if envelope.type == IMFrameType.error {
            let code = IMErrorCode(rawValue: Int(Wire.int(envelope.data, "code"))) ?? .internalError
            waiter.complete(.failure(IMRTCError(code, Wire.string(envelope.data, "msg"))))
            return true
        }
        waiter.complete(.success(IMRequestResult(envelope: envelope, data: decode(envelope))))
        return true
    }

    /// rejectAll 断线时把所有在途请求一次性失败掉。
    ///
    /// 不做这一步的话它们会一直挂到超时——用户看到的是「点了没反应」，
    /// 而真实原因（断线）明明早就知道了。
    func rejectAll(_ error: IMRTCError) {
        let all = waiters
        waiters.removeAll()
        for (_, waiter) in all {
            waiter.timer.cancel()
            waiter.complete(.failure(error))
        }
    }

    var inFlightCount: Int { waiters.count }
}
