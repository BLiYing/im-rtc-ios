import Foundation

/**
 一件要**按顺序**喂给状态机的事。

 # 为什么要有这个类型

 下行的东西不止「帧」一种：`sys.hello.ok`、断线、被踢也都要进状态机，
 而它们与帧之间的**先后顺序是有意义的**——hello.ok 要是排到它之后的帧后面，
 状态机就会拿着上一个会话的房间去处理新会话的帧。

 把四种东西装进同一个枚举、走同一条 `AsyncStream`，顺序才有唯一解释。
 旧实现是各自 `Task {}`，而无隔离的 Task 跑在全局并发执行器上，
 到达顺序没有任何保证（见 `IMCallEngine.frameInlet`）。

 内部类型：宿主看到的是回调表，不是这个。
 */
enum IMLoopWork: Sendable {
    /// 一帧下行信令（线路形状，snake_case）。
    case frame(String, [String: IMJSON])
    /// 握手成功。`resumed` 决定要不要重新协商上行。
    case connected(sessionID: String, resumed: Bool)
    /// 连接断了。关闭码由连接层单独上报给宿主，状态机只认「断了」。
    case disconnected
    /// 被踢。原因由连接层单独上报给宿主，状态机只认「被踢了」。
    case kickedOut
    /// 断得太久，服务端那一侧的会话已经不可能再恢复（§1.4）。
    case sessionUnrecoverable
}
