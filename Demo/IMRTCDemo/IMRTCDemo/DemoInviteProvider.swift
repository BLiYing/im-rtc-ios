import Foundation
import IMCallKit

/**
 Demo 的候选人 provider（HOST_INTEGRATION_DESIGN §3.4）：验证「按通话向宿主要候选人」
 这条路——分页、搜索、失败态、超时态。真实宿主会换成自己的群成员接口
 （IMProgram 是 `IMGroupInfo.members` / 超级群分页；容信是 `fetchGroupMemberInfosWithGroupId:`）。

 - 真实在线的 Demo 账号排前面，后面补几十个假成员凑够分页——选人页一页 20 个，
   `demoContacts` 只有 16 个，凑不出「滚到底翻页」这个场景。
 - 搜索词 `fail` 模拟服务端出错（选人页进失败态，带重试）；
   `slow` 模拟超时（故意不回调，Kit 的选人页 10 秒后按失败处理）。
 */
final class DemoInviteProvider: NSObject, IMInviteMemberProvider {
    /// 假成员数量：够翻两页以上。
    private static let fakeMemberCount = 44
    private static let pageSize = 20

    /// 全量名单：真实 Demo 账号在前，假成员在后。
    private lazy var allMembers: [IMInviteCandidate] = {
        let real = DemoSession.demoContacts.map { IMInviteCandidate(uid: $0, subtitle: "Demo 账号") }
        let fake = (1...Self.fakeMemberCount).map { index in
            IMInviteCandidate(uid: String(format: "member-%02d", index),
                              name: "群成员\(index)", subtitle: "假数据·凑分页")
        }
        return real + fake
    }()

    func inviteCandidates(for context: IMInviteContext, query: String, cursor: String?,
                          completion: @escaping IMInviteCandidatesCompletion) {
        let q = query.trimmingCharacters(in: .whitespaces)
        // 模拟超时：故意不回调。Kit 的选人页给 10 秒，超时按失败处理（§3.4）。
        if q == "slow" { return }
        if q == "fail" {
            let error = NSError(domain: "com.imrtc.demo", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "演示：服务端出错了"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { completion([], nil, error) }
            return
        }
        let matched = q.isEmpty ? allMembers : allMembers.filter {
            $0.uid.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q)
        }
        let start = Int(cursor ?? "") ?? 0
        guard start < matched.count else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { completion([], nil, nil) }
            return
        }
        let end = min(start + Self.pageSize, matched.count)
        let page = Array(matched[start..<end])
        let next = end < matched.count ? String(end) : nil
        // 留一点延迟：真实网络请求不是瞬间回来的，选人页的加载态才有机会被看见。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { completion(page, next, nil) }
    }

    /// Demo 不演示权限规则：一律放行。
    func canInvite(in context: IMInviteContext) -> Bool { true }
}
