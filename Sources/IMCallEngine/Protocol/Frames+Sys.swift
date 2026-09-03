import Foundation

/// sys 域：连接、鉴权、心跳、错误。见 §1 与 §7。
enum SysFrames {
    /// data 恒为 `{}` 的帧：sys.ping / sys.pong / 各种纯 ack。
    static let empty: IMFrameFields = [:]

    /// WS 打开后必须在 5 秒内发出的第一帧（§1.2）。
    ///
    /// token 走首帧而不是 URL 查询串：查询串会进网关日志、Referer 与浏览器历史。
    static let hello: IMFrameFields = [
        "protocol_version": .int(defaultValue: 1),
        "token": .string(),
        "device_id": .string(),
        // 重连恢复用；首次连接为 ""。
        "session_id": .string(),
        // 仅用于日志与灰度，**禁止参与逻辑**。
        "sdk": .string(),
    ]

    /// 服务端下发的限额，让客户端能本地预校验（§2.6）。
    static let limits: IMFrameFields = [
        "max_frame_bytes": .int(),
        "max_callees": .int(),
        "max_room_participants": .int(),
        "max_user_data_bytes": .int(),
        "ring_timeout_sec_default": .int(),
    ]

    /// 鉴权成功的应答。
    static let helloOK: IMFrameFields = [
        "uid": .string(),
        "device_id": .string(),
        "session_id": .string(),
        // 供客户端算时钟偏移，**只做展示**。
        "server_time_ms": .int(),
        "resumed": .bool(),
        "ping_interval_sec": .int(),
        "limits": .object(fields: limits),
    ]

    /// sys.error 的 data（§7）。
    static let error: IMFrameFields = [
        "code": .int(),
        "name": .string(),
        // 英文固定短语，给开发者看；**禁止直接显示给用户**。
        "msg": .string(),
        "for_type": .string(),
        "retryable": .bool(),
    ]
}
