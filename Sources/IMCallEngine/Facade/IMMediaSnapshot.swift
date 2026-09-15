import Foundation

/*
 `activeSpeakersDidChange` / `networkQualityDidChange` 的强类型元素（2026-09-15，四端命名对齐）。

 原先是 `[[String: Any]]`，ObjC 宿主要自己 `NSDictionary` 取键、拼错键名编译期看不出来。
 换成具名类型后拼错字段是编译错误，不是运行时读到 nil。**线路形状不变**——
 这两条回调本来就是服务端周期性快照（主讲人 300ms、网络质量 2s），
 只是把「拼出来的字典」搬到「拼出来的对象」，`IMEventDispatcher.callDelegate` 里做转换。
 */

/// 一位主讲人（`activeSpeakersDidChange` 的元素）。
@objc public final class IMSpeaker: NSObject {
    @objc public let uid: String
    /// 音量，0~100。
    @objc public let volume: Int

    @objc public init(uid: String, volume: Int) {
        self.uid = uid
        self.volume = volume
    }
}

/// 一位成员的网络质量（`networkQualityDidChange` 的元素）。
@objc public final class IMNetworkQuality: NSObject {
    @objc public let uid: String
    /// 质量档位，0~6（0 = 未知，协议 §3.5）。
    @objc public let level: Int

    @objc public init(uid: String, level: Int) {
        self.uid = uid
        self.level = level
    }
}
