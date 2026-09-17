#if canImport(UIKit)
import Foundation

/**
 会议画廊的**状态与算计**：这一页有谁、页码怎么写、钉住了谁
 （MEETING_ROOM_DESIGN §4.1 / §4.2 / §4.4）。

 它是通话页的第三个协作对象（前两个见 `IMOverlayTiles.swift`），理由同那两个：
 VC 膨胀时抽协作对象，不是抽私有方法进 extension（CONVENTIONS §2）。

 **它不碰视图**：算完交回一个 `Plan`，摆格子仍然是 `IMCallGridView` 的事。
 于是分页这件事在「格子怎么排」之外，与设计 §3 的门控表一致——格子组件行为不变。
 */
final class IMMeetingGallery {

    /// 当前页（从 0 起）。
    private(set) var page = 0
    /// 钉住的人；空串 = 没钉，在画廊里。
    private(set) var pinnedUID = ""
    /// 第一页排谁的记账（`IMMeetingPager.swift`）。
    private var order = IMFirstPageState()

    /// 一次渲染要的全部结论。
    struct Plan {
        /// 这一页要摆格子的远端（画廊），或底部条上的人（演讲者视图）。
        let visible: [IMParticipant]
        /// 此刻没有格子的人——他们要报 `none`。
        let offscreen: [IMParticipant]
        /// 钉住的那个人；nil = 画廊。
        let pinned: IMParticipant?
        /// 底部页码，空串 = 不画（人不够一页时）。
        let pageText: String
        /// 要不要按满页算行列（分页时恒 3×3，最后一页不放大）。
        let fixedTileCount: Int?
    }

    /// 演讲者视图底部条放几格：自己 + 最近 3 位（§4.4）。
    static let stripTiles = 4

    /**
     算这一轮该显示什么。

     `nowMS` 由调用方给（`Date` 的毫秒），让这套时间闸在测试里可控。
     */
    func plan(_ state: IMCallViewState, nowMS: Int64) -> Plan {
        let ordered = reorder(state, nowMS: nowMS)

        // 钉住的人走了要自动回画廊，否则主画面会一直盯着一个不在房里的 uid。
        if !pinnedUID.isEmpty, !ordered.contains(where: { $0.uid == pinnedUID }) {
            pinnedUID = ""
        }

        if let pinned = ordered.first(where: { $0.uid == pinnedUID }) {
            let rest = ordered.filter { $0.uid != pinned.uid }
            return Plan(visible: Array(rest.prefix(Self.stripTiles - 1)),
                        offscreen: Array(rest.dropFirst(Self.stripTiles - 1)),
                        pinned: pinned, pageText: "", fixedTileCount: nil)
        }

        guard imMeetingPaged(ordered.count) else {
            // 人不够一页：和群通话完全一样（§4.1），连页码都不画。
            return Plan(visible: ordered, offscreen: [], pinned: nil,
                        pageText: "", fixedTileCount: nil)
        }

        let total = imMeetingPageCount(ordered.count)
        page = imClampPage(page, total: total)
        let visible = imMeetingPageSlice(ordered, page: page)
        let shown = Set(visible.map(\.uid))
        return Plan(visible: visible,
                    offscreen: ordered.filter { !shown.contains($0.uid) },
                    pinned: nil,
                    pageText: imMeetingPageLabel(page: page, total: total),
                    fixedTileCount: IMMeetingTilesPerPage)
    }

    /// 翻页。`delta` 取 +1（下一页）/ -1（上一页）。返回页码有没有真的变。
    @discardableResult
    func turn(_ delta: Int, remoteCount: Int) -> Bool {
        let total = imMeetingPageCount(remoteCount)
        let next = imClampPage(page + delta, total: total)
        guard next != page else { return false }
        page = next
        return true
    }

    /// 钉住 / 取消钉住。双击同一个人 = 取消（与「再双击一次回去」的直觉一致）。
    func togglePin(_ uid: String) {
        pinnedUID = (pinnedUID == uid) ? "" : uid
    }

    /// 取消钉住（点 📌）。
    func unpin() {
        pinnedUID = ""
    }

    /// 离房 / 结束时归零，下一次进会议不带着上一次的页码与钉住。
    func reset() {
        page = 0
        pinnedUID = ""
        order = IMFirstPageState()
    }

    /// reorder 把成员按「第一页发言人优先、第二页起进房顺序」排一遍。
    private func reorder(_ state: IMCallViewState, nowMS: Int64) -> [IMParticipant] {
        let people = state.participants
        guard imMeetingPaged(people.count) else {
            // 一页装得下就没有「换进第一页」这回事，原样用进房顺序。
            return people
        }
        order = imReorderFirstPage(order, IMFirstPageInput(
            uids: people.map(\.uid),
            speaking: Set(people.filter(\.isSpeaking).map(\.uid)),
            withVideo: Set(people.filter(\.hasVideo).map(\.uid)),
            pinned: pinnedUID,
            nowMS: nowMS))

        var byUID = Dictionary(uniqueKeysWithValues: people.map { ($0.uid, $0) })
        var sorted: [IMParticipant] = []
        for uid in order.order {
            guard let found = byUID.removeValue(forKey: uid) else { continue }
            sorted.append(found)
        }
        // 排列还没跟上（刚进来的人）时兜底追加，一个都不许丢——
        // 丢了就是「有人在房里但没有格子」，而且没有任何报错。
        return sorted + people.filter { byUID[$0.uid] != nil }
    }
}
#endif
