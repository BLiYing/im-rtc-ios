import Foundation
@testable import IMCallEngine

/// 测试用的假 WebSocket。
///
/// CONVENTIONS §9：**时序类行为一律写测试，别靠真连接**。握手、心跳、重连全是时序，
/// 用假连接看得清；连真服务端只能得到「好像连上了」。
final class FakeWebSocket: IMWebSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: IMWebSocketHandlers?
    private var opened = false
    private var closedCode: Int?
    /// sent 是本端发出去的原始帧文本。
    private var sentFrames: [String] = []

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return opened && closedCode == nil
    }

    var sent: [String] {
        lock.lock(); defer { lock.unlock() }
        return sentFrames
    }

    var closedWith: Int? {
        lock.lock(); defer { lock.unlock() }
        return closedCode
    }

    func resume(handlers: IMWebSocketHandlers) {
        lock.lock(); self.handlers = handlers; lock.unlock()
    }

    func send(_ text: String) {
        lock.lock(); sentFrames.append(text); lock.unlock()
    }

    func close(code: Int, reason: String) {
        lock.lock()
        let already = closedCode != nil
        closedCode = code
        let h = handlers
        lock.unlock()
        guard !already else { return }
        h?.onClose(code, reason)
    }

    /// open 模拟连接建立。
    func open() {
        lock.lock(); opened = true; let h = handlers; lock.unlock()
        h?.onOpen()
    }

    /// receive 模拟收到一帧。
    func receive(_ raw: String) {
        lock.lock(); let h = handlers; lock.unlock()
        h?.onMessage(raw)
    }

    /// closeFromServer 模拟对端关闭（带协议关闭码）。
    func closeFromServer(_ code: Int, reason: String = "") {
        lock.lock()
        let already = closedCode != nil
        closedCode = code
        let h = handlers
        lock.unlock()
        guard !already else { return }
        h?.onClose(code, reason)
    }

    /// frames 返回已发出的帧（已解析）。
    func frames() -> [IMEnvelope] {
        sent.compactMap { try? IMEnvelope.decode($0) }
    }

    /// lastFrame 返回最后一帧。
    func lastFrame() -> IMEnvelope? { frames().last }
}

/// helloOKFrame 造一条握手成功的应答。
func helloOKFrame(reqID: String, sessionID: String = "s-1", resumed: Bool = false,
                  pingIntervalSec: Int = 15) -> String {
    """
    {"type":"sys.hello.ok","req_id":"\(reqID)","ts":1756876800123,"data":{\
    "uid":"alice","device_id":"d-1","session_id":"\(sessionID)",\
    "server_time_ms":1756876800123,"resumed":\(resumed),\
    "ping_interval_sec":\(pingIntervalSec),\
    "limits":{"max_frame_bytes":65536,"max_callees":8,"max_room_participants":9,\
    "max_user_data_bytes":4096,"ring_timeout_sec_default":30}}}
    """
}
