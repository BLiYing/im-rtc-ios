import Foundation

/*
 会议分页画廊的**纯算术**与**第一页排谁**（MEETING_ROOM_DESIGN §4.1 / §4.2）。

 分页是格子容器的**外层**：这里只回答「这一页该放哪几个人」与「第一页该是谁」，
 格子怎么排仍然是 `IMGrid.swift` 的事，`IMCallGridView` 本身一行不用改。
 群通话上限 9 人，永远只有一页，走的还是老路径。

 Web 的同一层是 `packages/call-uikit-react/src/layout/pager.ts` 与 `firstPage.ts`，
 Android 是 `IMMeetingPager.kt`，三端跑同一组场景。
 */

// MARK: - 分页

/// 会议每页几格。**自己占第一格**，所以远端只剩 8 个位置。
public let IMMeetingTilesPerPage = IMMaxTiles

/// 每页放得下几个远端。
public let IMMeetingRemotesPerPage = IMMaxRemoteTiles

/**
 总页数，**至少 1**（一个远端都没有时也有「第 1 页」，上面只有自己）。

 每页都留一格给自己，所以 49 个远端是 7 页而不是 6 页——这是「自己恒在第一格」
 那条规则的代价，与群通话保持一致，不给翻页另立一套。
 */
public func imMeetingPageCount(_ remoteCount: Int,
                               perPage: Int = IMMeetingRemotesPerPage) -> Int {
    guard perPage > 0 else { return 1 }
    return max(1, Int(ceil(Double(remoteCount) / Double(perPage))))
}

/// 把页码夹回 `0..<total`。人走了导致页数变少时要用它收回来。
public func imClampPage(_ page: Int, total: Int) -> Int {
    min(max(page, 0), max(total - 1, 0))
}

/**
 取某一页的远端。

 **最后一页不满时不补、也不放大**：格子和满页一样大，从左上往下排（§4.1）。
 放大的话层会从 l 跳到 m、还要多等一次关键帧，翻页时整屏重排。
 「不放大」由容器恒按满页算行列来保证，这里只负责切片。
 */
public func imMeetingPageSlice<T>(_ items: [T], page: Int,
                                  perPage: Int = IMMeetingRemotesPerPage) -> [T] {
    guard perPage > 0 else { return items }
    let start = page * perPage
    guard start < items.count else { return [] }
    return Array(items[start..<min(start + perPage, items.count)])
}

/// 这个房间此刻要不要分页。**总人数 ≤ 9 时和群通话完全一样**：没有页码、没有滑动（§4.1）。
public func imMeetingPaged(_ remoteCount: Int, perPage: Int = IMMeetingRemotesPerPage) -> Bool {
    remoteCount > perPage
}

/// 底部页码，`1 / 7` 这样。它**取代**了 M1 的「还有 N 人未显示」胶囊（§4.5）。
public func imMeetingPageLabel(page: Int, total: Int) -> String {
    "\(min(page + 1, total)) / \(total)"
}

// MARK: - 第一页排谁

/// 连续说话多久才够格换进第一页。
public let IMPromoteAfterMS: Int64 = 1_500
/// 在第一页待满这么久的人才可能被换出去。
public let IMMinStayMS: Int64 = 10_000
/// 第一页每这么久最多换一个人。
public let IMSwapCooldownMS: Int64 = 2_000

/**
 第一页排谁的全部记账（MEETING_ROOM_DESIGN §4.2）。**调用方持有它**，本模块只做纯变换。

 # 为什么不是「按说话时间排序」

 按说话时间直接排序的话，两个人来回搭话就会让第一页每 300ms 重排一次——
 `room.active_speakers` 本来就是 300ms 一条。用户看到的是格子不停地跳位置，谁也看不清。
 所以这里的每一条规则都是**防抖**：说够 1.5 s 才晋升、待满 10 s 才可能被换走、
 每 2 s 最多换一个人。

 # 第二页往后是稳定的

 这里只动第一页。第二页起恒按**进房顺序**——翻到后面的人不该因为有人说话而被挪走。
 */
public struct IMFirstPageState: Equatable, Sendable {
    /// 远端的当前排列。前 `firstPageSize` 个就是第一页。
    public var order: [String] = []
    /// uid → 这一轮连续说话是从什么时候开始的。
    public var speakingSince: [String: Int64] = [:]
    /// uid → 最近一次说话的时刻。从没说过话的人没有这一条。
    public var lastSpokeAt: [String: Int64] = [:]
    /// uid → 进入第一页的时刻，用来判「待满 10 s」。
    public var enteredAt: [String: Int64] = [:]
    /// 上一次换人的时刻，用来限频。
    public var lastSwapAt: Int64 = 0

    public init() {}
}

/// 一次重排要看的全部外部事实。
public struct IMFirstPageInput {
    /// 此刻房里的远端 uid，**按进房顺序**。
    public let uids: [String]
    /// 此刻正在说话的人。
    public let speaking: Set<String>
    /// 开着摄像头的人。同等条件下先换走没开摄像头的。
    public let withVideo: Set<String>
    /// 钉住的人（空串 = 没钉）。**钉住的人不许被换走**。
    public let pinned: String
    /// 第一页放得下几个远端。
    public let firstPageSize: Int
    public let nowMS: Int64

    public init(uids: [String], speaking: Set<String>, withVideo: Set<String>,
                pinned: String, firstPageSize: Int = IMMeetingRemotesPerPage, nowMS: Int64) {
        self.uids = uids
        self.speaking = speaking
        self.withVideo = withVideo
        self.pinned = pinned
        self.firstPageSize = firstPageSize
        self.nowMS = nowMS
    }
}

/**
 走一次规则，返回新的记账。

 调用时机：`room.active_speakers` 到了、有人进出、以及界面自己的节拍——
 **多调几次无害**，每一条规则都带时间闸。
 */
public func imReorderFirstPage(_ state: IMFirstPageState,
                               _ input: IMFirstPageInput) -> IMFirstPageState {
    imPromoteFirstPage(imTrackSpeaking(imSyncMembers(state, input), input), input)
}

/**
 让排列跟上房里的人。

 **有人离开时后面的人依次前补，只动那一页；新人追加到末尾**（§4.2）。
 直接按 `uids` 重排的话，第一页里熬上来的人会在任何一次进出时被打回进房顺序。
 */
func imSyncMembers(_ state: IMFirstPageState, _ input: IMFirstPageInput) -> IMFirstPageState {
    let present = Set(input.uids)
    let kept = state.order.filter { present.contains($0) }
    let known = Set(kept)
    let order = kept + input.uids.filter { !known.contains($0) }
    guard order != state.order else { return state }

    var next = state
    next.order = order
    // 一开始就在第一页的人（首次进房、或补位补上来的）也要记进入时刻，
    // 否则 10 s 的驻留判据没有起点，他们会被第一个说话的人立刻顶掉。
    for uid in order.prefix(max(input.firstPageSize, 0)) where next.enteredAt[uid] == nil {
        next.enteredAt[uid] = input.nowMS
    }
    next.enteredAt = next.enteredAt.filter { present.contains($0.key) }
    return next
}

/// 记「这一轮连续说了多久」与「最近一次说话是什么时候」。
func imTrackSpeaking(_ state: IMFirstPageState, _ input: IMFirstPageInput) -> IMFirstPageState {
    var next = state
    var since: [String: Int64] = [:]
    for uid in input.speaking {
        // 上一轮就在说的接着算；刚开口的从现在起算。
        since[uid] = state.speakingSince[uid] ?? input.nowMS
        next.lastSpokeAt[uid] = input.nowMS
    }
    next.speakingSince = since
    let present = Set(input.uids)
    next.lastSpokeAt = next.lastSpokeAt.filter { present.contains($0.key) }
    return next
}

/// 把够格的人换进第一页，一次最多一个。
func imPromoteFirstPage(_ state: IMFirstPageState,
                        _ input: IMFirstPageInput) -> IMFirstPageState {
    guard input.nowMS - state.lastSwapAt >= IMSwapCooldownMS else { return state }

    let size = max(input.firstPageSize, 0)
    let first = Array(state.order.prefix(size))
    let onFirst = Set(first)

    // 候选：不在第一页、且已经连续说了 ≥ 1.5 s。多个候选时挑说得最久的那个。
    var candidate = ""
    var candidateSince = Int64.max
    for (uid, since) in state.speakingSince.sorted(by: { $0.key < $1.key }) {
        guard !onFirst.contains(uid), state.order.contains(uid) else { continue }
        guard input.nowMS - since >= IMPromoteAfterMS else { continue }
        if since < candidateSince {
            candidate = uid
            candidateSince = since
        }
    }
    guard !candidate.isEmpty else { return state }

    let victim = imPickVictim(state, input, first: first)
    guard !victim.isEmpty,
          let victimIndex = state.order.firstIndex(of: victim),
          let candidateIndex = state.order.firstIndex(of: candidate) else { return state }

    var next = state
    // **换位置而不是插队**：插队会把第一页后半段整体挪一格，看上去像全屏重排。
    next.order[victimIndex] = candidate
    next.order[candidateIndex] = victim
    next.enteredAt[candidate] = input.nowMS
    next.lastSwapAt = input.nowMS
    return next
}

/**
 挑第一页里该让位的那个：**最久没发言的**，同等条件下先换没开摄像头的。

 只考虑**待满 10 s** 的人；钉住的人永远不动（他是被明确指定要看的）。
 一个都挑不出来就这一轮不换——宁可让候选多等一会儿，也不要把刚上来的人立刻顶掉。
 */
func imPickVictim(_ state: IMFirstPageState, _ input: IMFirstPageInput,
                  first: [String]) -> String {
    var victim = ""
    var victimSpoke = Int64.max
    var victimHasVideo = true
    for uid in first {
        guard uid != input.pinned else { continue }
        let entered = state.enteredAt[uid] ?? input.nowMS
        guard input.nowMS - entered >= IMMinStayMS else { continue }
        // 从没说过话的排在最前面（0 比任何时刻都早）。
        let spoke = state.lastSpokeAt[uid] ?? 0
        let hasVideo = input.withVideo.contains(uid)
        let better = spoke < victimSpoke || (spoke == victimSpoke && victimHasVideo && !hasVideo)
        guard better else { continue }
        victim = uid
        victimSpoke = spoke
        victimHasVideo = hasVideo
    }
    return victim
}
