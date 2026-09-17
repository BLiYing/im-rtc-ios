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
    /// `args` 只有「哪一条被拒了」这类需要带标识的才有（`publish_failed` 的 cid、`subscribe_failed` 的 track_id）。
    case internalEvent(name: String, args: [String: IMJSON] = [:])
}

/// 一次状态转移的产物。
public struct IMMachineOutput<State>: Sendable where State: Sendable {
    public let state: State
    public let send: [IMOutgoingFrame]
    public let emit: [IMEmittedEvent]
    /**
     这次 `act` 被状态机**就地拒绝**的码（一致性向量里 `act` 步骤的 `result`）；没拒绝是 nil。

     **不是事件**：它只回给发起这次调用的人（门面据此 throw），不经 `onError` 广播——
     一次失败只从一个出口报（server `docs/design/ACTION_RESULT_DESIGN.md` R3）。
     带它时 `send` / `emit` 为空、状态不变。
     */
    public let reject: IMErrorCode?

    public init(_ state: State, send: [IMOutgoingFrame] = [], emit: [IMEmittedEvent] = [],
                reject: IMErrorCode? = nil) {
        self.state = state
        self.send = send
        self.emit = emit
        self.reject = reject
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

    /// string 的默认值重载：字段缺失**或为空串**都取 `fallback`。
    /// `RoomStateMachine` 里 `max_layer` 的两处 `.isEmpty ? "m" : ...` 用它替掉。
    static func string(_ data: [String: IMJSON], _ key: String, fallback: String) -> String {
        let value = string(data, key)
        return value.isEmpty ? fallback : value
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

/// out 是状态机 reducer 的通用构造：把新状态包成一次 `IMMachineOutput`。
///
/// `CallStateMachine` 与 `RoomStateMachine` 原先各有一份逐行相同的 `static func out`，
/// 现在共用这一个——两边的类型参数不同（`IMCallContext` / `IMRoomContext`），泛型化之后
/// 各自内部对 `out(...)` 的调用不用改一个字，Swift 的名字查找会先找到本类型作用域，
/// 这里作用域里没有同名静态方法了，就落到这个全局函数上。
func out<State>(_ ctx: State, send: [IMOutgoingFrame] = [],
                emit: [IMEmittedEvent] = []) -> IMMachineOutput<State> where State: Sendable {
    IMMachineOutput(ctx, send: send, emit: emit)
}

/// invalidStateOutput 是不变量 I8/R1 共同的落点：错误状态下的调用**本地拒绝**，
/// 不发上去、不抛事件，只在输出里带上 `reject`（交给调用方）。`CallStateMachine.invalidState` 与
/// `RoomStateMachine.localReject` 函数体完全一样，只是上下文类型不同，合到这一处。
func invalidStateOutput<State>(_ ctx: State) -> IMMachineOutput<State> where State: Sendable {
    IMMachineOutput(ctx, reject: .invalidState)
}

/// IMEmittedCallbackName 收着几个要在多处按名字**过滤**的回调名字面量。
///
/// `onDisconnected` / `onKickedOut` 由连接层独占上报（见 `IMFrameLoop.dispatch` 的注释），
/// 状态机那一份要在帧泵里被滤掉；`IMEventDispatcher.names` 拿同一个字符串当键。
/// 两处原先各拼了一遍 `"onDisconnected"` / `"onKickedOut"`，集中到这里。
enum IMEmittedCallbackName {
    static let onDisconnected = "onDisconnected"
    static let onKickedOut = "onKickedOut"
}
