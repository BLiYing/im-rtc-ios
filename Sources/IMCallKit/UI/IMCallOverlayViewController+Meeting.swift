#if canImport(UIKit)
import UIKit
import IMCallEngine

/*
 通话页的**会议房**那一半：分页画廊、翻页手势、钉住进演讲者视图、成员列表
 （MEETING_ROOM_DESIGN §4.1 / §4.4 / §4.6）。

 与群通话拆成两条路径，是因为设计 §3 的门控表要求「格子组件行为不变」：
 `IMCallGridView` 仍然只回答「给定这一页的格子怎么排」，分页是它的外层。
 群通话完全不经过本文件。
 */
extension IMCallOverlayViewController {

    /// 此刻是不是钉住了某个人（决定画廊与演讲者视图谁露面）。
    var speakerPinned: Bool { !meeting.pinnedUID.isEmpty }

    /// installMeetingGestures 装翻页手势。**只认横向滑**——竖向留给别的手势。
    func installMeetingGestures() {
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(onSwipePage(_:)))
            swipe.direction = direction
            gridView.addGestureRecognizer(swipe)
        }
    }

    @objc func onSwipePage(_ gesture: UISwipeGestureRecognizer) {
        let state = controller.state
        guard state.isMeeting, !speakerPinned else { return }
        // 左滑 = 看下一页。
        let delta = gesture.direction == .left ? 1 : -1
        guard meeting.turn(delta, remoteCount: state.participants.count) else { return }
        render(state)
    }

    @objc func onUnpin() {
        meeting.unpin()
        render(controller.state)
    }

    /**
     点标题复制房号（§4.6 的配套）：房号是这一屏里**要报给别人**的那个东西。

     只有会议房的标题可点（`titleIsCopyable`）——1v1 与群通话的标题是人名，复制它没有意义。
     反馈走 `hint`：状态行的一次性提示本来就是这个用途，且会自己到点撤掉。
     */
    @objc func onCopyRoomID() {
        let roomID = controller.state.roomID
        guard controller.state.isMeeting, !roomID.isEmpty else { return }
        UIPasteboard.general.string = roomID
        controller.apply(.hint("已复制房间号 \(roomID)"))
    }

    @objc func onMembers() {
        let state = controller.state
        let list = IMMemberListViewController(members: state.participants,
                                              selfMicOn: state.selfState.micOn,
                                              selfCameraOn: state.selfState.cameraOn,
                                              resolver: controller.profileResolver)
        present(list, animated: true)
    }

    /**
     renderMeeting 画会议房的舞台。

     两种形态共用一套格子（按 uid 复用，见 `IMRemoteTiles`）：
     画廊时摆进 `gridView`，钉住时主画面进 `speakerStage`、其余进底部条。
     **没有格子的人一律报 `none`**——引擎在会议房里会把它翻译成「五秒后退订」。
     */
    func renderMeeting(_ state: IMCallViewState) {
        let plan = meeting.plan(state, nowMS: Int64(Date().timeIntervalSince1970 * 1000))

        // 只留还要用的格子，其余摘掉（卸载要成对，否则解码器还占着）。
        // 翻走的人多留五秒：引擎那边也正等着这五秒才退订，滑回来就一次协商都不用。
        var keep = Set(plan.visible.map(\.uid))
        if let pinned = plan.pinned { keep.insert(pinned.uid) }
        remoteTiles.retire(keeping: keep,
                           linger: Set(plan.offscreen.map(\.uid)),
                           grace: IMRoomMachine.unsubscribeHysteresis)

        applySelfTile(state, avatarSize: IMKitTheme.current.avatarSmall)
        controller.attachLocalPreview(to: state.mediaType == "video" ? selfTile.renderView : nil)

        if let pinned = plan.pinned {
            renderSpeaker(state, pinned: pinned, strip: plan.visible)
        } else {
            renderGallery(state, plan: plan)
        }

        /*
         层上界：主画面 h、底部条 l、画廊按格数算；没格子的人 none（§4.3）。

         **`none` 要先报**：会议房里它就是「排退订」，而新一页的 `l` 是「订阅」，
         订阅那头顶着 16 路的硬上限。反过来先报 `l` 的话，翻页的那一瞬间
         旧页还整整占着 8 路、新页又要 8 路，第 17 路直接被本地拒掉——
         表现成「翻过去有一格永远是头像」，而且一条报错都不抛。
        */
        for p in plan.offscreen {
            remoteTiles.report(p.uid, layer: "none", hasVideo: p.hasVideo)
        }
        let galleryLayer = imTileLayer(plan.fixedTileCount ?? (plan.visible.count + 1))
        for p in plan.visible {
            remoteTiles.report(p.uid, layer: plan.pinned == nil ? galleryLayer : "l",
                               hasVideo: p.hasVideo)
        }
        if let pinned = plan.pinned {
            remoteTiles.report(pinned.uid, layer: "h", hasVideo: pinned.hasVideo)
        }
    }

    private func renderGallery(_ state: IMCallViewState, plan: IMMeetingGallery.Plan) {
        speakerStage.detach()
        var ordered: [UIView] = [selfTile] // 自己恒占第一格，每页都在
        for p in plan.visible {
            ordered.append(tile(for: p))
        }
        gridView.fixedTileCount = plan.fixedTileCount
        gridView.pageText = plan.pageText
        // 分页之后没有「看不见的人」这回事，只有「在别的页上」——那枚 M1 胶囊就此退役。
        gridView.hiddenCount = 0
        gridView.layout(ordered)
    }

    private func renderSpeaker(_ state: IMCallViewState, pinned: IMParticipant,
                               strip: [IMParticipant]) {
        gridView.layout([])
        gridView.pageText = ""
        gridView.hiddenCount = 0
        speakerStage.setMain(tile(for: pinned, avatarSize: IMKitTheme.current.avatarLarge))
        // 底部条第一格恒是自己，与画廊「自己占第一格」同一条规则。
        speakerStage.setStrip([selfTile] + strip.map { tile(for: $0) })
    }

    /// tile 取某人的格子并刷上最新内容。**按 uid 复用**，不重建（重建会让画面闪）。
    private func tile(for p: IMParticipant,
                      avatarSize: CGFloat = IMKitTheme.current.avatarSmall) -> IMVideoTileView {
        let view = remoteTiles.tile(for: p.uid)
        view.apply(uid: p.uid,
                   label: imResolvedName(controller.profileResolver, uid: p.uid, fallback: p.uid),
                   hasVideo: p.hasVideo, hasAudio: p.hasAudio, isSpeaking: p.isSpeaking,
                   volume: p.volume, isRinging: !p.hasAccepted, settled: p.settled,
                   networkLevel: p.networkLevel, avatarSize: avatarSize,
                   avatarImage: imResolvedAvatar(controller.profileResolver, uid: p.uid))
        attachPinGesture(view, uid: p.uid)
        return view
    }

    /**
     attachPinGesture 给格子装「双击钉住」（§4.4）。

     **双击才算**，不是单击：单击留给「显示 / 隐藏控制条」那一套手势，
     而钉住是一个明确的、不该被误触发的动作。每个格子只装一次——
     格子按 uid 复用，重复装会让一次双击触发好几回。
     */
    private func attachPinGesture(_ view: IMVideoTileView, uid: String) {
        guard view.gestureRecognizers?.contains(where: { $0 is UITapGestureRecognizer }) != true else {
            return
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTileDoubleTap(_:)))
        tap.numberOfTapsRequired = 2
        view.isUserInteractionEnabled = true
        view.addGestureRecognizer(tap)
    }

    @objc func onTileDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard controller.state.isMeeting,
              let tile = gesture.view as? IMVideoTileView,
              let uid = remoteTiles.uid(of: tile) else { return }
        meeting.togglePin(uid)
        render(controller.state)
    }
}
#endif
