import Foundation

/**
 ObjC 宿主接 SDK 日志的入口。

 `IMRTCLog` 是 Swift enum、`IMRTCLogSink` 是非 `@objc` 协议，ObjC 宿主（IMProgram）既设不了级别也装不了接收端，
 SDK 的日志就只剩 `os.Logger` 一路，进不了宿主自己的日志系统（回传服务端、落文件）。

 ObjC 侧：`[IMRTCLogBridge installWithMinLevel:handler:]`；`level` 取 `IMRTCLogLevel` 的 rawValue（0 debug … 3 error）。
 **并联不替换**，与 `IMRTCLog.setSink` 同语义：`os.Logger` 那一路照样写。
 */
@objc public final class IMRTCLogBridge: NSObject {
    private final class BlockSink: IMRTCLogSink, @unchecked Sendable {
        let handler: (Int, String) -> Void
        init(_ handler: @escaping (Int, String) -> Void) { self.handler = handler }
        func write(level: IMRTCLogLevel, message: String, fields: [String: String]) {
            let tail = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
            handler(level.rawValue, tail.isEmpty ? message : "\(message) \(tail)")
        }
    }

    /// 装上接收端并设最低级别。重复调用以最后一次为准。`handler` 会在**任意线程**被调用。
    @objc public static func install(minLevel: Int, handler: @escaping (Int, String) -> Void) {
        IMRTCLog.setLevel(IMRTCLogLevel(rawValue: minLevel) ?? .info)
        IMRTCLog.setSink(BlockSink(handler))
    }

    /// 摘掉接收端。
    @objc public static func uninstall() {
        IMRTCLog.setSink(nil)
    }
}
