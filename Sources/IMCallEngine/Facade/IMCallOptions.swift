import Foundation

/**
 `call(_:mediaType:options:)` 的选项（HOST_INTEGRATION_DESIGN §3.2/§3.3，2026-09-15）。

 群通话邀请要做到「宿主零 fork」，缺的就是这几个字段：`chatGroupID` 让 Kit 的
 「添加成员」知道该向宿主要哪个群的候选人，`userData` 是宿主的私有透传字节，
 `timeoutSec` 让宿主能按场景（比如会议提醒电话）改振铃时长。

 三个字段**原样进 `call.invite`**（协议 §4.1），SDK 不解析、只做长度与格式的本地校验
 （见 `IMCallEngine.call(_:mediaType:options:)`）。
 */
@objc public final class IMCallOptions: NSObject {
    /// 是否按群通话规则处理（即使只邀 1 人，见协议 §4.1）。
    @objc public var isGroup: Bool
    /// 宿主自己的群号，opaque，≤64 字节 UTF-8，禁止含空白与换行；不属于群的通话留空。
    @objc public var chatGroupID: String
    /// opaque 字节串，≤4096 字节，原样透传给被叫（`onCallReceived`）与接通者（`onCallBegin`）。
    @objc public var userData: String
    /// 振铃超时，秒。**0 = 使用协议默认值 30**；非零时原样进 `call.invite`（服务端按 §2.6 钳到 5~120）。
    @objc public var timeoutSec: Int

    @objc public init(isGroup: Bool = false, chatGroupID: String = "",
                      userData: String = "", timeoutSec: Int = 0) {
        self.isGroup = isGroup
        self.chatGroupID = chatGroupID
        self.userData = userData
        self.timeoutSec = timeoutSec
        super.init()
    }

    @objc public override convenience init() {
        self.init(isGroup: false)
    }
}
