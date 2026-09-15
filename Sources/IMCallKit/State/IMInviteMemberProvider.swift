import Foundation
#if canImport(UIKit)
import UIKit
#endif

/*
 「按这通电话向宿主要候选人」的钩子（HOST_INTEGRATION_DESIGN §3.4，2026-09-15）。

 群通话要做到「宿主零 fork」，缺的就是这一个：Kit 原先的候选名单是全局静态数组
 （`IMCallKitConfig.inviteCandidates`），不知道「哪一通、哪个群」，也不能分页搜索。
 有了这个 provider，Kit 每次弹选人页 / 每次翻页都带上这通电话的上下文去问宿主。

 与 `IMProfileResolving`（`IMProfileResolver.swift`）同样的边界：Kit 不内置联系人
 系统，也不知道宿主的群成员存在哪、要不要分页、超级群要不要走搜索接口——这些全部
 留给宿主的 provider 实现，Kit 只负责在正确的时机、带着正确的上下文去问。
 */

/// 一次「添加成员」发生在哪通电话上（§3.4「共同语义」）。
@objc public final class IMInviteContext: NSObject {
    /// 这通电话的 call_id。
    @objc public let callID: String
    /// 宿主自己的群号，可空——不属于一个群的临时多人通话也能加人（provider 返回通讯录即可）。
    @objc public let chatGroupID: String
    /// 宿主经 `call()` 透传的私有字节，provider 需要的话自己解析，Kit 不碰。
    @objc public let userData: String
    /// 发起人 uid。
    @objc public let callerUID: String
    @objc public let mediaType: String
    /// **此刻在通话里 + 正在振铃的人，含自己**。选人页拿它标「已在通话中」。
    @objc public let participantUIDs: [String]
    /// 还能再加几个人（= 9 − `participantUIDs` 人数）。
    @objc public let slotsLeft: Int

    @objc public init(callID: String, chatGroupID: String, userData: String, callerUID: String,
                      mediaType: String, participantUIDs: [String], slotsLeft: Int) {
        self.callID = callID
        self.chatGroupID = chatGroupID
        self.userData = userData
        self.callerUID = callerUID
        self.mediaType = mediaType
        self.participantUIDs = participantUIDs
        self.slotsLeft = slotsLeft
        super.init()
    }
}

/// 「添加成员」的候选人。**名单是宿主给的**——Kit 不内置联系人系统（CONVENTIONS §11）。
@objc public final class IMInviteCandidate: NSObject {
    @objc public let uid: String
    @objc public let name: String
    /// 头像地址，可空。Kit 自己去取图（不像 `IMProfileResolving` 要求已加载好的 `UIImage`）——
    /// provider 给的候选人往往是网络分页拉回来的，一次性给 URL 更自然。
    @objc public let avatarURL: URL?
    /// 副标题，可空（"在线" / 部门名一类，选人页列表第二行）。
    @objc public let subtitle: String?
    /// 默认 true。false = 这个人不能被选中（`unselectableReason` 说明原因），置灰显示但不隐藏。
    @objc public let selectable: Bool
    /// `selectable == false` 时的原因（"已被禁言" 一类），可空。
    @objc public let unselectableReason: String?

    @objc public init(uid: String, name: String = "", avatarURL: URL? = nil, subtitle: String? = nil,
                      selectable: Bool = true, unselectableReason: String? = nil) {
        self.uid = uid
        self.name = name.isEmpty ? uid : name
        self.avatarURL = avatarURL
        self.subtitle = subtitle
        self.selectable = selectable
        self.unselectableReason = unselectableReason
        super.init()
    }
}

/**
 候选人分页结果的完成回调。

 `items` / `nextCursor` 在成功时有意义；`error` 非空表示这一页取失败（选人页据此进
 失败态，带重试）。**必须在合理时间内回调**——Kit 给 10 秒超时，超时按失败处理
 （容信 iOS 现有实现在账号全无效时不回调，页面永远转圈，这是要避免的形状）。
 `nextCursor` 为 `nil`/空串表示没有下一页。
 */
public typealias IMInviteCandidatesCompletion =
    (_ items: [IMInviteCandidate], _ nextCursor: String?, _ error: NSError?) -> Void

/// provider：`(ctx, query, cursor) → (items, nextCursor) | error`（§3.4）。
@objc public protocol IMInviteMemberProvider: AnyObject {

    /// 按这通电话取一页候选人。`query` 空串 = 默认列表；`cursor` 为空 = 第一页。
    /// 小群一次返回全部（`nextCursor` 给 nil）；超级群走宿主自己的服务端搜索分页。
    func inviteCandidates(for context: IMInviteContext, query: String, cursor: String?,
                          completion: @escaping IMInviteCandidatesCompletion)

    #if canImport(UIKit)
    /**
     整页接管选人页。返回 `true` 表示宿主自己弹了页面，Kit **不再弹自带选人页**；
     宿主选完把 uid 交回 `completion`（空数组 = 用户取消），**由 Kit 调 `inviteMore`**。

     不实现、或实现了但返回 `false`：Kit 弹自带的 `IMInvitePickerViewController`，
     用 `inviteCandidates(for:query:cursor:completion:)` 取数据。
     */
    @objc optional func presentInvitePicker(for context: IMInviteContext,
                                            from viewController: UIViewController,
                                            completion: @escaping ([String]) -> Void) -> Bool
    #endif

    /// 宿主的权限规则（例：群禁言时仅管理员可加人）。默认 `true`。
    @objc optional func canInvite(in context: IMInviteContext) -> Bool
}
