import Foundation

/*
 把状态机产出的 `IMEmittedEvent`（线路形状、snake_case）翻译成宿主的两种接法。

 # 为什么 delegate 与 block 从同一个 switch 出去

 CONVENTIONS §4 要求两种形式都提供（ObjC 宿主两种习惯都有）。但**两套并行的
 分发代码迟早会分叉**——加了一个回调只记得改一边，而那种漏项在编译期看不出来。
 所以这里只有一个 switch：先把事件变成一个 `IMCallEvent`，
 再由它同时喂给 delegate 和所有 block 观察者。

 # 回调都切主线程

 CONVENTIONS §5：宿主拿到回调就画界面，别让它们自己 hop。
 用 `async` 不用 `sync`——`DispatchQueue.main.sync` 是死锁常客，规范里明令禁止。
 */

/// 一个公开事件的名字。**与 `IMCallEngineDelegate` 的方法一一对应**。
@objc public enum IMCallEventName: Int, Sendable {
    case connected, disconnected, kickedOut, error
    case callReceived, callBegin, callEnd
    case callCancelled, callRejected, callBusy, callNoAnswer, callMissed, handledOnOtherDevice
    case userEnter, userLeave, userAccept, userReject, userNoResponse
    case userAudioAvailable, userVideoAvailable
    case activeSpeakers, networkQuality, firstVideoFrame
    case roomJoined, roomLeft, roomClosed
}

extension IMCallEventName {
    /**
     事件的**公开名字**，与 Web/桌面同名（设计文档 §7.5）。

     必须显式写这张表：`IMCallEventName` 是 `@objc enum ... : Int`，
     字符串插值出来是 `IMCallEventName(rawValue: 0)` 这种东西——
     日志里全是它的话，「四端合一条时间轴」那条链路就等于白做了。
     （实测踩过：第一版回传上来的日志就是这个样子。）
     */
    public var name: String {
        switch self {
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .kickedOut: return "kickedOut"
        case .error: return "error"
        case .callReceived: return "callReceived"
        case .callBegin: return "callBegin"
        case .callEnd: return "callEnd"
        case .callCancelled: return "callCancelled"
        case .callRejected: return "callRejected"
        case .callBusy: return "callBusy"
        case .callNoAnswer: return "callNoAnswer"
        case .callMissed: return "callMissed"
        case .handledOnOtherDevice: return "handledOnOtherDevice"
        case .userEnter: return "userEnter"
        case .userLeave: return "userLeave"
        case .userAccept: return "userAccept"
        case .userReject: return "userReject"
        case .userNoResponse: return "userNoResponse"
        case .userAudioAvailable: return "userAudioAvailable"
        case .userVideoAvailable: return "userVideoAvailable"
        case .activeSpeakers: return "activeSpeakers"
        case .networkQuality: return "networkQuality"
        case .firstVideoFrame: return "firstVideoFrame"
        case .roomJoined: return "roomJoined"
        case .roomLeft: return "roomLeft"
        case .roomClosed: return "roomClosed"
        }
    }
}

/// 一个公开事件。**block 接法拿到的就是它**。
///
/// 常用字段给了具名属性；其余的从 `payload` 里按协议的 snake_case 键取
/// （与一致性向量、与另外三端同名）。
@objc public final class IMCallEvent: NSObject {
    @objc public let name: IMCallEventName
    /// 事件的全部数据，键是协议的 snake_case 名。
    @objc public let payload: [String: Any]

    @objc public var uid: String { payload["uid"] as? String ?? "" }
    @objc public var callID: String { payload["call_id"] as? String ?? "" }
    @objc public var roomID: String { payload["room_id"] as? String ?? "" }

    init(_ name: IMCallEventName, _ payload: [String: Any]) {
        self.name = name
        self.payload = payload
    }
}

/// 分发器。**持有 delegate 用 weak**（CONVENTIONS §7）。
final class IMEventDispatcher {
    weak var delegate: IMCallEngineDelegate?
    /// block 观察者。key 是退订用的 token。
    private var observers: [UUID: (IMCallEvent) -> Void] = [:]
    /// engine 自己的弱引用：delegate 方法的第一个参数要传它。
    private weak var engine: IMCallEngine?

    /// mu 只保护 observers。取锁期间**不回调外部**——宿主代码可能重入。
    private let mu = NSLock()

    init(engine: IMCallEngine) {
        self.engine = engine
    }

    func addObserver(_ handler: @escaping (IMCallEvent) -> Void) -> UUID {
        let token = UUID()
        mu.lock()
        observers[token] = handler
        mu.unlock()
        return token
    }

    func removeObserver(_ token: UUID) {
        mu.lock()
        observers[token] = nil
        mu.unlock()
    }

    /// emit 分发一条状态机事件。**无法识别的回调名会被丢掉并记一条日志**——
    /// 那说明状态机新加了一个回调而这里忘了接，是我们自己的实现 bug。
    func emit(_ event: IMEmittedEvent) {
        guard let name = Self.names[event.callback] else {
            IMRTCLog.error("未接入的回调，宿主收不到", ["callback": event.callback])
            return
        }
        deliver(IMCallEvent(name, event.args.mapValues(Self.plain)))
    }

    /// emitConnectionEvent 分发连接层自己产生的事件（关闭码只有它知道）。
    func emitConnectionEvent(_ name: IMCallEventName, _ payload: [String: Any]) {
        deliver(IMCallEvent(name, payload))
    }

    /// 周期性事件：主讲人 300ms 一次、网络质量 2s 一次。**降到 debug**，
    /// 否则一通电话几百条，把状态跃迁那几条淹掉。
    private static let periodic: Set<IMCallEventName> = [.activeSpeakers, .networkQuality]

    private func deliver(_ event: IMCallEvent) {
        /*
         **每一个公开事件都进日志。** 这是「四端日志合到一条时间轴」那条链路的前提：
         宿主装一个 sink 就能拿到完整事件流，不用再从事件面板里手动复制粘贴。
         （Web 端同一处：engineBus.ts。）
         */
        let fields = event.payload.mapValues { Self.fieldText($0) }
        if Self.periodic.contains(event.name) {
            IMRTCLog.debug("event " + event.name.name, fields)
        } else {
            IMRTCLog.info("event " + event.name.name, fields)
        }

        mu.lock()
        let handlers = Array(observers.values)
        mu.unlock()

        DispatchQueue.main.async { [weak self] in
            for handler in handlers { handler(event) }
            guard let self, let engine = self.engine, let delegate = self.delegate else { return }
            self.callDelegate(delegate, engine, event)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func callDelegate(_ d: IMCallEngineDelegate, _ e: IMCallEngine, _ v: IMCallEvent) {
        let p = v.payload
        func str(_ key: String) -> String { p[key] as? String ?? "" }
        func flag(_ key: String) -> Bool { p[key] as? Bool ?? false }
        func num(_ key: String) -> Int { (p[key] as? NSNumber)?.intValue ?? 0 }
        func rows(_ key: String) -> [[String: Any]] { p[key] as? [[String: Any]] ?? [] }
        func strs(_ key: String) -> [String] { p[key] as? [String] ?? [] }

        switch v.name {
        case .connected:
            d.callEngine?(e, didConnect: str("session_id"), resumed: flag("resumed"))
        case .disconnected:
            d.callEngine?(e, didDisconnect: num("code"), willReconnect: flag("will_reconnect"))
        case .kickedOut:
            d.callEngineDidGetKickedOut?(e)
        case .error:
            d.callEngine?(e, didFailWithError: Self.nsError(p))

        case .callReceived:
            d.callEngine?(e, didReceiveCall: str("call_id"), caller: str("caller"),
                          calleeIDs: strs("callee_ids"),
                          mediaType: str("media_type"), isGroup: flag("is_group"))
        case .callBegin:
            d.callEngine?(e, callDidBegin: str("call_id"), roomID: str("room_id"),
                          mediaType: str("media_type"), isGroup: flag("is_group"),
                          role: str("role"))
        case .callEnd:
            d.callEngine?(e, callDidEnd: str("call_id"), reason: str("reason"),
                          durationSec: num("duration_sec"), endedBy: str("ended_by"))

        case .callCancelled:
            d.callEngine?(e, callWasCancelledBy: str("by"))
        case .callRejected:
            d.callEngine?(e, callWasRejectedBy: str("uid"))
        case .callBusy:
            d.callEngine?(e, calleeIsBusy: str("uid"))
        case .callNoAnswer:
            d.callEngine?(e, calleeDidNotAnswer: str("uid"))
        case .callMissed:
            d.callEngine?(e, missedCall: str("call_id"), caller: str("caller"), reason: str("reason"))
        case .handledOnOtherDevice:
            d.callEngine?(e, callHandledOnOtherDevice: str("call_id"), action: str("action"))

        case .userEnter:
            d.callEngine?(e, userDidEnter: str("uid"))
        case .userLeave:
            d.callEngine?(e, userDidLeave: str("uid"))
        case .userAccept:
            d.callEngine?(e, userDidAccept: str("uid"))
        case .userReject:
            d.callEngine?(e, userDidReject: str("uid"))
        case .userNoResponse:
            d.callEngine?(e, userDidNotRespond: str("uid"))
        case .userAudioAvailable:
            d.callEngine?(e, user: str("uid"), audioAvailable: flag("available"))
        case .userVideoAvailable:
            d.callEngine?(e, user: str("uid"), videoAvailable: flag("available"))

        case .activeSpeakers:
            d.callEngine?(e, activeSpeakersDidChange: rows("speakers"))
        case .networkQuality:
            d.callEngine?(e, networkQualityDidChange: rows("entries"))
        case .firstVideoFrame:
            d.callEngine?(e, didReceiveFirstVideoFrame: str("uid"), trackID: str("track_id"))

        case .roomJoined:
            d.callEngine?(e, didJoinRoom: str("room_id"))
        case .roomLeft:
            d.callEngine?(e, didLeaveRoom: str("room_id"))
        case .roomClosed:
            d.callEngine?(e, roomDidClose: str("room_id"), reason: str("reason"))
        }
    }

    /// names 是状态机的回调名 → 公开事件名。**这张表就是那座桥**。
    private static let names: [String: IMCallEventName] = [
        "onConnected": .connected, "onDisconnected": .disconnected,
        "onKickedOut": .kickedOut, "onError": .error,
        "onCallReceived": .callReceived, "onCallBegin": .callBegin, "onCallEnd": .callEnd,
        "onCallCancelled": .callCancelled, "onCallRejected": .callRejected,
        "onCallBusy": .callBusy, "onCallNoAnswer": .callNoAnswer,
        "onCallMissed": .callMissed,
        "onHandledOnOtherDevice": .handledOnOtherDevice,
        "onUserEnter": .userEnter, "onUserLeave": .userLeave,
        "onUserAccept": .userAccept, "onUserReject": .userReject,
        "onUserNoResponse": .userNoResponse,
        "onUserAudioAvailable": .userAudioAvailable,
        "onUserVideoAvailable": .userVideoAvailable,
        "onActiveSpeakers": .activeSpeakers, "onNetworkQuality": .networkQuality,
        "onFirstVideoFrame": .firstVideoFrame,
        "onRoomJoined": .roomJoined, "onRoomLeft": .roomLeft, "onRoomClosed": .roomClosed,
    ]

    /// fieldText 把载荷压成一行文本进日志；数组/字典走 JSON。
    private static func fieldText(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    /// plain 把 `IMJSON` 摊成 ObjC 能读的普通值。
    private static func plain(_ value: IMJSON) -> Any {
        switch value {
        case let .string(text): return text
        case let .int(number): return NSNumber(value: number)
        case let .bool(flag): return NSNumber(value: flag)
        case let .array(items): return items.map(plain)
        case let .object(fields): return fields.mapValues(plain)
        }
    }

    /// nsError 把错误事件桥成 `NSError`——公开面必须 ObjC 可用（CONVENTIONS §4）。
    private static func nsError(_ payload: [String: Any]) -> NSError {
        let code = (payload["code"] as? NSNumber)?.intValue ?? IMErrorCode.internalError.rawValue
        let name = payload["name"] as? String ?? ""
        return NSError(domain: IMRTCErrorDomain, code: code, userInfo: [
            NSLocalizedDescriptionKey: name,
            IMRTCErrorNameKey: name,
        ])
    }
}

/// NSError 的 domain。**公开常量**：ObjC 宿主要靠它区分是不是我们的错误。
public let IMRTCErrorDomain = "com.imrtc.engine"
/// `userInfo` 里放协议错误名（snake_case）的键。
public let IMRTCErrorNameKey = "IMRTCErrorName"
