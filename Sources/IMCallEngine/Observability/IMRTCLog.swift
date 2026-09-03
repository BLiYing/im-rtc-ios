import Foundation
import os

/*
 SDK 的唯一日志入口（CONVENTIONS §6）。

 **禁止 print / NSLog / debugPrint**——姊妹项目上这条写在规范里很久，
 因为有兼容桥接兜底、「看起来没坏」，累计出过 54 处违规而无人察觉。
 `scripts/check-logging.sh` 会拦住它们。

 级别按「谁该被叫醒」分而不是按「有多详细」：
   debug 开发细节 / info **状态跃迁**（进房、接通、结束）/
   warn 可自愈异常（重连、丢包超阈）/ error 需要人介入。
 一次 1v1 通话的 info **应该是个位数条**——压测时 info 量随包数增长，
 就说明有人把 debug 写成了 info。
 */
public enum IMRTCLogLevel: Int, Sendable, Comparable {
    case debug = 0, info, warn, error, off

    public static func < (lhs: IMRTCLogLevel, rhs: IMRTCLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 日志接收端。宿主可以换成自己的日志系统。
public protocol IMRTCLogSink: AnyObject, Sendable {
    func write(level: IMRTCLogLevel, message: String, fields: [String: String])
}

public enum IMRTCLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var level: IMRTCLogLevel = .info
    nonisolated(unsafe) private static var sink: IMRTCLogSink?
    private static let logger = Logger(subsystem: "com.imrtc.engine", category: "engine")

    /// setLevel 设置最低输出级别。
    public static func setLevel(_ newLevel: IMRTCLogLevel) {
        lock.lock(); defer { lock.unlock() }
        level = newLevel
    }

    /// setSink 换一个日志接收端；传 nil 回到 `os.Logger`。
    public static func setSink(_ newSink: IMRTCLogSink?) {
        lock.lock(); defer { lock.unlock() }
        sink = newSink
    }

    public static func debug(_ message: String, _ fields: [String: String] = [:]) {
        emit(.debug, message, fields)
    }

    public static func info(_ message: String, _ fields: [String: String] = [:]) {
        emit(.info, message, fields)
    }

    public static func warn(_ message: String, _ fields: [String: String] = [:]) {
        emit(.warn, message, fields)
    }

    public static func error(_ message: String, _ fields: [String: String] = [:]) {
        emit(.error, message, fields)
    }

    private static func emit(_ messageLevel: IMRTCLogLevel, _ message: String,
                             _ fields: [String: String]) {
        lock.lock()
        let threshold = level
        let target = sink
        lock.unlock()

        guard messageLevel >= threshold else { return }
        if let target {
            target.write(level: messageLevel, message: message, fields: fields)
            return
        }
        let rendered = fields.isEmpty
            ? message
            : message + " " + fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
        switch messageLevel {
        case .debug: logger.debug("\(rendered, privacy: .public)")
        case .info: logger.info("\(rendered, privacy: .public)")
        case .warn: logger.warning("\(rendered, privacy: .public)")
        case .error, .off: logger.error("\(rendered, privacy: .public)")
        }
    }

    /// redact 脱敏凭据：**只留前 6 位 + 长度**（CONVENTIONS §6）。
    ///
    /// token 整条进日志的后果不是「多了几行」，是任何拿到日志的人都能冒充这个用户。
    public static func redact(_ credential: String) -> String {
        guard !credential.isEmpty else { return "(empty)" }
        let head = String(credential.prefix(6))
        return "\(head)…(len=\(credential.count))"
    }

    /// redactSDP 把 SDP 压成一行摘要。
    ///
    /// 要看完整 SDP 请用 Chrome 的 `webrtc-internals` 或 `RTCPeerConnection` 的统计，
    /// **不要靠日志**——一条 SDP 几千字节，打两条就把日志淹了。
    public static func redactSDP(_ sdp: String) -> String {
        let lines = sdp.split(separator: "\n")
        let media = lines.filter { $0.hasPrefix("m=") }.map { $0.prefix(10) }.joined(separator: ",")
        return "sdp(lines=\(lines.count), \(media))"
    }

    /// redactCandidate 只留传输协议与候选类型——地址与端口会暴露内网拓扑。
    public static func redactCandidate(_ candidate: String) -> String {
        let parts = candidate.split(separator: " ")
        let transport = parts.count > 2 ? String(parts[2]).lowercased() : "?"
        let typeIndex = parts.firstIndex(of: "typ")
        let type = typeIndex.flatMap { index -> String? in
            let next = parts.index(after: index)
            return next < parts.endIndex ? String(parts[next]) : nil
        } ?? "?"
        return "candidate(\(transport)/\(type))"
    }
}
