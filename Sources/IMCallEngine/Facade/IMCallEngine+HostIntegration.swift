import Foundation

/*
 宿主对接 M1/M8（HOST_INTEGRATION_DESIGN §3.2/§3.3）：带选项发起群通话、主动加入
 进行中的群通话。拆成独立文件是体量红线（CONVENTIONS §2）——`IMCallEngine.swift`
 已经排满了登录与基础通话动作。
 */
extension IMCallEngine {

    /// chatGroupID 的线路上限（协议 §2.6）。
    private static let maxChatGroupIDBytes = 64
    /// userData 的线路上限（协议 §2.6）。
    private static let maxUserDataBytes = 4096

    /**
     call 发起通话，带完整选项（群号 / user_data / 振铃超时）。

     **calleeIDs 上限 8 个**（自己 + 8 = 9 人）、**名单里不能有自己**，与旧的
     `call(_:mediaType:isGroup:)` 同一条规矩、同一个出口。

     `options.chatGroupID` 超 64 字节或含空白、`options.userData` 超 4096 字节时
     **本地就地拒掉**——与「名单里有自己」同一个出口（先 `callDidEnd(.error)`、再 throw `1004`），
     不上线路（HOST_INTEGRATION_DESIGN §3.3）。三个字段随后原样进 `call.invite`，
     SDK 不解析、不做群成员校验，那是宿主的事。

     **这两道本地关卡只在 `idle` 时抢在状态机前面拦**：`callDidEnd(.error)` 假定「界面刚乐观地进了
     『正在呼叫…』，收起它」——如果这通 `call()` 其实是在另一通电话已经在进行时误调的（比如名单里
     误含自己），此刻并没有那个「正在呼叫…」界面，抢先 throw 1004 只会给那通**正在进行的**通话
     发一条假的 `onCallEnd`，把它错杀。不是 `idle` 就放行给状态机，让它按 §5.1 正常拒成 `2005`
     （不发 `onCallEnd`，不碰当前那通）。

     **返回服务端分配的 callID**（取自 `call.invite.ok`）。
     */
    @objc public func call(_ calleeIDs: [String], mediaType: String,
                           options: IMCallOptions) async throws -> String {
        try guardNotDestroyed()
        let idle = await state.call.state == .idle
        let me = uid
        if idle, !me.isEmpty, calleeIDs.contains(me) {
            throw rejectCallLocally(reason: "呼叫名单里含自己")
        }
        if idle, let badField = Self.invalidHostField(options) {
            throw rejectCallLocally(reason: badField)
        }
        var args: [String: IMJSON] = [
            "callee_ids": .array(calleeIDs.map { .string($0) }),
            "media_type": .string(mediaType),
            "is_group": .bool(options.isGroup),
            "chat_group_id": .string(options.chatGroupID),
            "user_data": .string(options.userData),
        ]
        // 0 = 用协议默认值 30，**不上线路**——上了会把线路默认值覆盖成 0（§2.6 越界钳到边界，
        // 而 0 恰好 < 下限 5，钳出来的是 5 秒，不是宿主想要的「用默认值」）。
        if options.timeoutSec > 0 { args["timeout_sec"] = .int(Int64(options.timeoutSec)) }
        let reply = try await act("call", args)
        return reply["call_id"]?.stringValue ?? ""
    }

    /// invalidHostField 校验 chatGroupID / userData 的本地限额（协议 §2.6）。合规返回 nil。
    private static func invalidHostField(_ options: IMCallOptions) -> String? {
        let chatGroupID = options.chatGroupID
        if !chatGroupID.isEmpty {
            if chatGroupID.utf8.count > maxChatGroupIDBytes {
                return "chatGroupID 超过 \(maxChatGroupIDBytes) 字节"
            }
            if chatGroupID.contains(where: { $0.isWhitespace || $0.isNewline }) {
                return "chatGroupID 不能含空白或换行"
            }
        }
        if options.userData.utf8.count > maxUserDataBytes {
            return "userData 超过 \(maxUserDataBytes) 字节"
        }
        return nil
    }

    /**
     rejectCallLocally 就地拒掉一次 `call()`：抛一条 `onCallEnd(error)`，返回要 throw 给调用方的 `1004`。

     调用方（Kit / 宿主）在调 `call()` 之前多半已经切到「正在呼叫…」，只交回一个错误的话
     靠回调驱动的界面不知道该退回哪儿；`onCallEnd` 让它有地方收场——与「服务端拒了 invite」
     （call_failed）同一个出口。错误本身只从 throw 出去，不再发 onError（ACTION_RESULT_DESIGN R3）。
     */
    func rejectCallLocally(reason: String) -> IMRTCError {
        dispatcher.emit(IMEmittedEvent("onCallEnd", [
            "call_id": .string(""),
            "reason": .string(IMCallEndReason.error.wireValue),
            "duration_sec": .int(0),
            "ended_by": .string(""),
        ]))
        IMRTCLog.warn("call() 本地校验不通过，已就地拒掉", ["reason": reason])
        return IMRTCError(.badParams, reason, forType: IMFrameType.callInvite)
    }

    /**
     joinCall 主动加入一通正在进行的群通话（协议 §4.1 `call.join`，2026-09-15 实现）。

     **「怎么知道有通话在进行中」不在本协议里**——宿主拿 webhook `call.started`，或后台
     `GET /v1/calls?chat_group_id=<群号>&active=1` 自己在群里摆「进行中」横幅
     （HOST_INTEGRATION_DESIGN §3.5/§9）。这里只负责把 `call_id` 送上去。

     加入者直接算「已接听」，不经过 `ringing`。**返回 = 服务端受理了（`call.join.ok`）**，接通回调随后到。
     被拒（`1401` 不存在 / `1402` 已结束 / `1202` 满员 / `1408` 在别的通话中 / `1409` 宿主拒绝…）时
     throw 那个码，同时（先于 throw）照发 `callDidEnd(.error)`——状态机已经进了 `accepting`，界面收起靠它
     （状态机 §5.1：`idle` 下 `join_call()` 与 `call()` 共用 `call_failed` 收场路径）。
     */
    @objc public func joinCall(_ callID: String) async throws {
        try await act("join_call", ["call_id": .string(callID)])
    }
}
