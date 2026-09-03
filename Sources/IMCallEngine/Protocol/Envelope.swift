import Foundation

/*
 信封 `{type, req_id, ts, data}` —— 协议 §2。

 四个字段**都是必填**，一个都不能省：
   · `type`   非空字符串；
   · `req_id` 请求/应答成对，事件恒为空串（**空串不等于缺失**，缺了就是非法信封）；
   · `ts`     整数毫秒；
   · `data`   对象，**不能是 null**，没有内容就写 `{}`。

 「req_id 缺失非法但可以是空串」这条看着别扭，但它换来一件事：
 接收方不需要区分「没写」和「写了空」，**两种情况在四种语言里的表现从来就不一致**。
 */
public struct IMEnvelope: Equatable, Sendable {
    public let type: String
    public let reqID: String
    public let timestampMS: Int64
    public let data: [String: IMJSON]

    public init(type: String, reqID: String, timestampMS: Int64, data: [String: IMJSON]) {
        self.type = type
        self.reqID = reqID
        self.timestampMS = timestampMS
        self.data = data
    }
}

extension IMEnvelope {
    /// maxFrameBytes 是单帧上限（协议 §1.3），超了服务端直接以 4400 关连接。
    public static let maxFrameBytes = 65536

    /// okSuffix 是应答帧的后缀：`room.join` 的应答是 `room.join.ok`。
    public static let okSuffix = ".ok"

    /// okType 返回某个请求帧的应答类型。
    public static func okType(_ type: String) -> String { type + okSuffix }

    /// isEvent 判断这是不是服务端主动推的事件（req_id 恒为空串）。
    public var isEvent: Bool { reqID.isEmpty }

    /// decode 解一帧。
    ///
    /// 顺序是**先信封、再编码硬规则**：信封坏了就没必要再往里看，
    /// 而且两类错误的码不同（badEnvelope vs badParams），先后颠倒会报错码。
    public static func decode(_ raw: String) throws -> IMEnvelope {
        guard raw.utf8.count <= maxFrameBytes else {
            throw IMRTCError(.frameTooLarge, "帧 \(raw.utf8.count) 字节 > 上限 \(maxFrameBytes)")
        }
        let parsed = try IMJSON.parse(raw)
        guard let top = parsed.objectValue else {
            throw IMRTCError(.badEnvelope, "信封必须是 JSON 对象")
        }

        guard let type = top["type"]?.stringValue, !type.isEmpty else {
            throw IMRTCError(.badEnvelope, "type 缺失或不是非空字符串")
        }
        guard let reqID = top["req_id"]?.stringValue else {
            // **不是「可以省略」**：事件用空串表达，省略就是非法信封。
            throw IMRTCError(.badEnvelope, "req_id 缺失；事件请显式写空串")
        }
        guard let ts = top["ts"]?.intValue else {
            throw IMRTCError(.badEnvelope, "ts 缺失或不是整数毫秒")
        }
        guard let data = top["data"]?.objectValue else {
            throw IMRTCError(.badEnvelope, "data 缺失或不是对象；没有内容请写 {}")
        }

        try Discipline.check(data)
        return IMEnvelope(type: type, reqID: reqID, timestampMS: ts, data: data)
    }

    /// encode 把一帧序列化成文本。
    public func encode() throws -> String {
        let object = IMJSON.object([
            "type": .string(type),
            "req_id": .string(reqID),
            "ts": .int(timestampMS),
            "data": .object(data),
        ])
        let bytes = try object.encoded()
        guard bytes.count <= Self.maxFrameBytes else {
            throw IMRTCError(.frameTooLarge, "帧 \(bytes.count) 字节 > 上限 \(Self.maxFrameBytes)")
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw IMRTCError(.internalError, "帧序列化后不是合法 UTF-8")
        }
        return text
    }
}
