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
     **本地就地拒掉**——与「名单里有自己」同一个出口（`onError(1004)` + `onCallEnd(error)`），
     不上线路（HOST_INTEGRATION_DESIGN §3.3）。三个字段随后原样进 `call.invite`，
     SDK 不解析、不做群成员校验，那是宿主的事。
     */
    @objc public func call(_ calleeIDs: [String], mediaType: String,
                           options: IMCallOptions) async {
        let me = uid
        if !me.isEmpty, calleeIDs.contains(me) {
            rejectCallLocally(reason: "呼叫名单里含自己")
            return
        }
        if let badField = Self.invalidHostField(options) {
            rejectCallLocally(reason: badField)
            return
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
        await loop.dispatch(.act(op: "call", args: args))
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
     rejectCallLocally 就地拒掉一次 `call()`，走「所有结束分支的唯一出口」。

     调用方（Kit / 宿主）在调 `call()` 之前多半已经切到「正在呼叫…」，只抛一条 error
     界面不知道该退回哪儿；`onCallEnd` 让它有地方收场（与旧 `call(_:mediaType:isGroup:)`
     的「名单里含自己」同一个出口，见 `IMCallEngine.swift`）。
     */
    private func rejectCallLocally(reason: String) {
        dispatcher.emit(IMEmittedEvent("onError", [
            "code": .int(Int64(IMErrorCode.badParams.rawValue)),
            "name": .string(IMErrorCode.badParams.name),
        ]))
        dispatcher.emit(IMEmittedEvent("onCallEnd", [
            "call_id": .string(""),
            "reason": .string(IMCallEndReason.error.wireValue),
            "duration_sec": .int(0),
            "ended_by": .string(""),
        ]))
        IMRTCLog.warn("call() 本地校验不通过，已就地拒掉", ["reason": reason])
    }

    /**
     joinCall 主动加入一通正在进行的群通话（协议 §4.1 `call.join`，2026-09-15 实现）。

     **「怎么知道有通话在进行中」不在本协议里**——宿主拿 webhook `call.started`，或后台
     `GET /v1/calls?chat_group_id=<群号>&active=1` 自己在群里摆「进行中」横幅
     （HOST_INTEGRATION_DESIGN §3.5/§9）。这里只负责把 `call_id` 送上去。

     加入者直接算「已接听」，不经过 `ringing`；被拒（不存在 / 已结束 / 已在这通电话里 /
     在别的通话中 / 满员 / 宿主拒绝）与 `call()` 被拒同一个出口：`onError` + `onCallEnd(error)`
     （状态机 §5.1：`idle` 下 `join_call()` 与 `call()` 共用 `call_failed` 收场路径）。
     */
    @objc public func joinCall(_ callID: String) async {
        await loop.dispatch(.act(op: "join_call", args: ["call_id": .string(callID)]))
    }
}
