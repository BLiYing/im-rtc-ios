import Foundation

/*
 状态机的公共类型。

 状态机是**纯函数 reducer**：`(state, input) -> (state, send, emit)`。
 不碰网络、不碰 UI、不碰计时器——所以它能被
 `docs/conformance` 下的 `call_fsm.json` / `room_fsm.json`逐条驱动，
 与另外三端跑**同一份**用例，而且完全不需要模拟器。
 */

/// 状态机要求发出去的一帧（线路形状，snake_case）。
public struct IMOutgoingFrame: Equatable, Sendable {
    public let type: String
    public let data: [String: IMJSON]

    public init(_ type: String, _ data: [String: IMJSON] = [:]) {
        self.type = type
        self.data = data
    }
}

/// 状态机要求抛给宿主的一个回调。
///
/// `args` 的键用**协议的 snake_case 名**，与一致性向量一致；
/// 由门面转成 Swift 惯用形式再交给宿主。
public struct IMEmittedEvent: Equatable, Sendable {
    public let callback: String
    public let args: [String: IMJSON]

    public init(_ callback: String, _ args: [String: IMJSON] = [:]) {
        self.callback = callback
        self.args = args
    }
}

/// 驱动状态机的三种输入（与向量的 act / recv / internal 一一对应）。
public enum IMMachineInput: Sendable {
    /// 宿主调用了 engine 的公开方法。
    case act(op: String, args: [String: IMJSON] = [:])
    /// 收到一条下行帧。
    case recv(type: String, data: [String: IMJSON])
    /// engine 内部事件，既不来自信令也不来自宿主（如媒体就绪）。
    case internalEvent(name: String)
}

/// 一次状态转移的产物。
public struct IMMachineOutput<State>: Sendable where State: Sendable {
    public let state: State
    public let send: [IMOutgoingFrame]
    public let emit: [IMEmittedEvent]

    public init(_ state: State, send: [IMOutgoingFrame] = [], emit: [IMEmittedEvent] = []) {
        self.state = state
        self.send = send
        self.emit = emit
    }
}

/// 从线路数据里安全取值的小工具。
///
/// **缺字段不报错、取默认值**：帧级解码已经补过默认值了，这里只是防御性兜底；
/// 状态机不该因为一个字段没写就抛异常。
enum Wire {
    static func string(_ data: [String: IMJSON], _ key: String) -> String {
        data[key]?.stringValue ?? ""
    }

    static func int(_ data: [String: IMJSON], _ key: String) -> Int64 {
        data[key]?.intValue ?? 0
    }

    static func bool(_ data: [String: IMJSON], _ key: String) -> Bool {
        data[key]?.boolValue ?? false
    }

    static func stringArray(_ data: [String: IMJSON], _ key: String) -> [String] {
        (data[key]?.arrayValue ?? []).compactMap(\.stringValue)
    }
}
