#if canImport(UIKit)
import UIKit
import IMCallEngine

/*
 通话主界面，三种版式（规范 §03 / §04）：
 · **audio**：语音通话、拨出中 —— 96 头像 + 名字 + 状态（拨出视频时右上叠本端预览）；
 · **video**：1v1 视频通话中 —— 远端全屏 + 本端小窗，单击小窗互换，控制条 3s 自动隐藏；
 · **grid**：群通话 / 会议 —— 九宫格（加人入口只在标题栏右上角那一颗）。

 **三种版式做在一个 VC 里而不是三个**：静音状态、发言高亮、计时这些在每一态都要维护，
 拆开就得维护三遍，而且态与态之间切换会闪一下。版式由 `imPickLayout` 决定（纯函数，有单测）。

 全屏深色，不随宿主主题（草图 §03）。头部 / 橙条 / 提示卡在 IMCallChromeViews.swift，
 小窗手势在 IMPipView.swift，语音页在 IMAudioStageView.swift。
 */
public final class IMCallOverlayViewController: UIViewController {

    let controller: IMCallController
    private let gradient = CAGradientLayer()
    private let banner = IMTopBannerView()
    private let header = IMCallHeaderView()
    private let stage = UIView()
    /**
     全屏画面的宿主：**在整个 view 的最底下一层，铺满整屏**（含安全区外的那两条）。

     原先全屏画面钉在 `stage` 里，而 stage 是「头部下方、控制条上方」那一块——
     于是视频顶上顶着一条黑边、底下再一条，真机上看着就是「没有全屏」。
     现在头部与控制条浮在画面上（它们自带 scrim），画面自己铺满。
    */
    private let videoFull = UIView()
    private let audioStage = IMAudioStageView()
    let gridView = IMCallGridView()
    /// 会议钉住后的演讲者视图（MEETING_ROOM_DESIGN §4.4）。只在会议房用得到。
    let speakerStage = IMSpeakerStageView()
    /// 会议画廊的页码、钉住与第一页排序（`IMMeetingGallery.swift`）。
    let meeting = IMMeetingGallery()
    private let pip = IMPipView()
    /// 结束画面那一句话。**结束态不复用通话页的骨架**——那会把接通后才有的按钮铺出来。
    private let endedLabel = UILabel()
    /// 本端格子。群通话里它是格子之一；1v1 里在小窗（互换后到全屏）。
    let selfTile = IMVideoTileView()
    private let controlsScrim = CAGradientLayer()
    /// 控制条两排按钮（IMCallControls.swift）。
    private let controls = IMCallControls()
    private var controlsStack: UIStackView { controls.stack }
    /// 远端格子与层上报（IMOverlayTiles.swift）。
    lazy var remoteTiles = IMRemoteTiles(controller: controller)
    /// 当前把哪个格子钉成了全屏（视频版式）。
    private lazy var fullStage = IMFullStage(host: videoFull)

    /// 计时器。**持有方释放时必须 cancel**（CONVENTIONS §5）。
    private var tickTimer: DispatchSourceTimer?
    private var networkBannerTimer: DispatchSourceTimer?
    /**
     控制条的「3s 后淡出、任意触摸恢复」。判据与 Android 对齐，细节全在 `IMChromeGate`。

     `lazy` 是因为它要捕获 `self`（判据里要读 `currentLayout` 与 `controller.state`），
     而那些在属性初始化那一刻还不能用。
    */
    private lazy var chrome = IMChromeGate(
        views: [header, controlsStack],
        layers: [controlsScrim],
        canAutoHide: { [weak self] in
            guard let self else { return false }
            return self.currentLayout == .video && self.controller.state.phase == .active
        },
        onChanged: { [weak self] visible in
            guard let self else { return }
            self.pip.liftsForControls = visible && self.currentLayout == .video
        })
    private var poorNetworkShown = false

    public init(controller: IMCallController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    deinit {
        tickTimer?.cancel()
        chrome.cancel()
        networkBannerTimer?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        build()
        controller.addObserver(self)
        render(controller.state)
        startTicking()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient.frame = view.bounds
        controlsScrim.frame = CGRect(x: 0, y: view.bounds.height - 160, width: view.bounds.width, height: 160)
        pip.layoutInContainer()
    }

    /// 通话页固定深色，状态栏也要跟着变白（草图 §03）。
    public override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - 搭界面

    private func build() {
        let theme = IMKitTheme.current
        view.backgroundColor = theme.overlayBackground
        // 语音页的径向渐变底（规范 §02）。视频页被画面盖住时把它藏掉。
        gradient.type = .radial
        gradient.colors = [theme.callGradientTop.cgColor, theme.callGradientBottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 1.2, y: 0.7)
        view.layer.insertSublayer(gradient, at: 0)
        // 视频页控制条底下垫一层透明 → 黑 55% 的渐变，否则浅色画面上白图标看不见（规范 §04）。
        controlsScrim.colors = [UIColor.clear.cgColor, theme.scrim.cgColor]
        controlsScrim.isHidden = true

        endedLabel.font = .systemFont(ofSize: 17)
        endedLabel.textColor = theme.primaryText
        endedLabel.textAlignment = .center
        endedLabel.numberOfLines = 0

        // videoFull 先加：它要在最底下一层，头部与控制条浮在它上面。
        videoFull.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoFull)
        for child in [header, stage, endedLabel, controlsStack, banner] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        view.layer.insertSublayer(controlsScrim, below: controlsStack.layer)
        for child in [audioStage, gridView, speakerStage, pip] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            stage.addSubview(child)
        }
        pip.translatesAutoresizingMaskIntoConstraints = true // 小窗自己管 frame

        let guide = view.safeAreaLayoutGuide
        /*
         **三段显式约束**：标题贴顶、控制条贴底、中间区域吃掉全部剩余空间——不靠 UIStackView 的
         hugging 优先级博弈（它没有固有尺寸，优先级对它不起作用；实测就是「内容缩在顶部一条细带」）。
         头部与控制条都钉了高度（规范 §04：64 / 96），中间的高度就被完全确定了。
        */
        videoFull.imPinEdges(to: view)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            /*
             **橙条挂在标题栏下方，不与它抢同一条。**

             原先它和 `header` 钉的是同一个锚点（`guide.top + 8`），于是「正在重连…」
             直接盖在标题与通话时长上——两条信息都在，但叠着谁也读不清。
             （Android 上同一处的表现更糟：那边橙条不在受 inset 影响的容器里，
             全面屏上直接钻进状态栏。两端 2026-09-09 一起挪的。）
            */
            banner.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            banner.centerXAnchor.constraint(equalTo: guide.centerXAnchor),

            stage.topAnchor.constraint(equalTo: header.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: controlsStack.topAnchor),
            endedLabel.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            endedLabel.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            endedLabel.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 24),
            endedLabel.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -24),

            controlsStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            controlsStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -26),
        ])
        audioStage.imPinEdges(to: stage)
        gridView.imPinEdges(to: stage, inset: 12)
        speakerStage.imPinEdges(to: stage, inset: 12)
        speakerStage.isHidden = true

        header.minimizeButton.addTarget(self, action: #selector(onMinimize), for: .touchUpInside)
        header.inviteButton.addTarget(self, action: #selector(onInvite), for: .touchUpInside)
        header.membersButton.addTarget(self, action: #selector(onMembers), for: .touchUpInside)
        header.onTitleTap = { [weak self] in self?.onCopyRoomID() }
        speakerStage.unpinButton.addTarget(self, action: #selector(onUnpin), for: .touchUpInside)
        installMeetingGestures()
        controls.micButton.addTarget(self, action: #selector(onMic), for: .touchUpInside)
        controls.cameraButton.addTarget(self, action: #selector(onCamera), for: .touchUpInside)
        controls.endButton.addTarget(self, action: #selector(onEnd), for: .touchUpInside)
        controls.acceptButton.addTarget(self, action: #selector(onAccept), for: .touchUpInside)
        controls.rejectButton.addTarget(self, action: #selector(onReject), for: .touchUpInside)
        controls.speakerButton.addTarget(self, action: #selector(onSpeaker), for: .touchUpInside)
        controls.switchCameraButton.addTarget(self, action: #selector(onSwitchCamera), for: .touchUpInside)
        pip.onTap = { [weak self] in
            guard let self else { return }
            // 拨出中小窗里只有自己、对端还没画面，没什么可换。
            guard imPickLayout(for: self.controller.state) == .video else { return }
            self.controller.setSwapped(!self.controller.state.isSwapped)
        }
        // 单击画面空白处：显示 / 隐藏控制条（视频版式才生效）。
        stage.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onStageTap)))
    }

    // MARK: - 动作

    @objc private func onMic() { controller.toggleMic() }
    @objc private func onCamera() { controller.toggleCamera() }
    @objc private func onMinimize() { controller.setMinimized(true) }
    @objc private func onEnd() { controller.end() }
    @objc private func onAccept() { controller.accept() }
    @objc private func onReject() { controller.reject() }
    @objc private func onSpeaker() { controller.toggleSpeaker() }
    @objc private func onSwitchCamera() { controller.switchCamera() }
    /**
     加人入口（草图 §05）。**取名单优先级见 `IMInvitePickerViewController`**：这里只决定
     「弹不弹、弹谁的」——宿主的权限规则（`canInvite`）先过一道，宿主接管了选人页
     （`presentInvitePicker`）就不弹 Kit 自己那个。
     */
    @objc private func onInvite() {
        guard controller.canStartInvite() else {
            controller.apply(.hint(imT("hint.inviteNoPermission")))
            return
        }
        if let provider = controller.inviteMemberProvider,
           provider.presentInvitePicker?(for: controller.inviteContext, from: self,
                                          completion: { [weak controller] uids in
               guard !uids.isEmpty else { return }
               controller?.inviteMore(uids)
           }) == true {
            return
        }
        let picker = IMInvitePickerViewController(controller: controller)
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @objc private func onStageTap() {
        guard currentLayout == .video else { return }
        chrome.set(visible: !chrome.visible)
    }

    // MARK: - 渲染

    private var currentLayout: IMCallLayout {
        imPickLayout(for: controller.state)
    }

    /// startTicking 每秒刷一次时长。**只在通话中跑**，其余状态没有时长可显示。
    private func startTicking() {
        tickTimer = imEvery(1, on: .main) { [weak self] in
            guard let self, self.controller.state.phase == .active else { return }
            self.renderHeader(self.controller.state)
        }
    }

    func render(_ state: IMCallViewState) {
        let layout = currentLayout
        let isEnded = state.phase == .ended
        renderHeader(state)
        endedLabel.isHidden = !isEnded
        endedLabel.text = imCallStatusLine(state)
        gradient.isHidden = layout == .video && !isEnded
        controlsScrim.isHidden = layout != .video || isEnded
        audioStage.isHidden = layout != .audio || isEnded
        /*
         **先把走掉的钉住对象清掉，再读 `speakerPinned`。**

         清理原本只发生在 `meeting.plan()` 里，而那是本方法**后半段**才调的：
         被钉的人离开的那一帧，这两行仍然认为还钉着——画廊继续藏着、演讲者视图露着，
         可主画面那一格刚被摘掉。界面上是整块黑屏，要等下一次渲染节拍（1 s）才回来。
        */
        if state.isMeeting { meeting.dropPinnedIfGone(state.participants) }
        gridView.isHidden = layout != .grid || isEnded || speakerPinned
        speakerStage.isHidden = layout != .grid || isEnded || !speakerPinned
        pip.isHidden = isEnded
        controls.render(state)
        renderBanner(state)
        if isEnded {
            controller.attachLocalPreview(to: nil)
            // 下一次进会议不带着上一次的页码与钉住。
            meeting.reset()
            speakerStage.detach()
            // **全屏画面也要摘掉**：1v1 视频挂断后版式仍是 .video，不摘的话结束原因那行字
            // 压在对方最后一帧上——看着像通话还在。Android 的 render 一直是这么做的。
            fullStage.unpin()
            return
        }
        // 来电页上看得见自己：摄像头开着且早就授权过才起，响铃时不申请（见 imShouldPreviewWhileRinging）。
        // 只在全屏来电页起——横幅上没有预览位，起了就是摄像头灯亮着却看不见自己。
        if state.phase == .incoming { controller.startRingingPreviewIfAllowed() }
        switch layout {
        case .audio: renderAudio(state)
        case .video: renderVideo(state)
        case .grid: renderGrid(state)
        }
        // 视频版式外 chrome 永远可见；进视频版式时重新计时。
        if layout != .video { chrome.set(visible: true, arm: false) } else if chrome.visible { chrome.armAutoHide() }
    }

    private func renderHeader(_ state: IMCallViewState) {
        let peerLevel = state.isGroup ? 0 : (state.participants.first?.networkLevel ?? 0)
        /*
         **呼叫中与来电页的标题栏留空。** 那两屏的正中间已经是「大头像 + 名字 + 状态」，
         顶部再写一遍同样的名字和同一行状态，同一句话在一屏里出现两次。
         接通之后才有真正只属于顶栏的信息（对方名字 + 计时器 + 网络条）。
        */
        let bare = state.phase == .incoming || state.phase == .outgoing
        header.apply(title: bare ? "" : imCallTitle(state, resolver: controller.profileResolver), subtitle: bare ? "" : imCallStatusLine(state),
                     networkLevel: state.phase == .active ? peerLevel : 0,
                     showsMinimize: state.phase != .incoming && state.phase != .ended,
                     showsInvite: imCanShowInvite(for: state),
                     // 会议房右上角是「👥 N」（§4.6）；它与加人按钮共用那个位置，互斥。
                     // **收场之后也不给**：会议已经散了，点开是一张名单在数还没走干净的人。
                     memberCount: state.isMeeting && !bare && state.phase != .ended
                         ? state.participants.count + 1 : 0,
                     // 标题是房号时才可点（复制）。收场之后不给：房间已经散了。
                     titleIsCopyable: state.isMeeting && !bare && state.phase != .ended
                         && !state.roomID.isEmpty)
    }

    /// 顶部橙条：正在重连 / 连接已断开 / 对方网络不佳（2s 后收成角标，**不一直霸占顶部**）。
    private func renderBanner(_ state: IMCallViewState) {
        switch state.connection {
        case .reconnecting: banner.apply(text: imT("banner.reconnecting")); return
        case .lost: banner.apply(text: imT("banner.lost")); return
        case .ok: break
        }
        let poor = !state.isGroup && state.participants.contains { imIsNetworkPoor(level: $0.networkLevel) } // 只做 1v1
        if poor, !poorNetworkShown {
            poorNetworkShown = true
            banner.apply(text: imT("banner.peerNetwork"))
            networkBannerTimer?.cancel()
            networkBannerTimer = imAfter(IMKitTheme.current.networkBannerHold, on: .main) { [weak self] in self?.banner.apply(text: "") }
        } else if !poor {
            poorNetworkShown = false
            banner.apply(text: "")
        }
    }

    // MARK: 三种版式

    private func renderAudio(_ state: IMCallViewState) {
        let peer = state.participants.first
        // 来电页显示「把你拉进来的人」（与横幅同一个 uid）；其余时候是对端。
        let who = state.phase == .incoming && !state.inviterUID.isEmpty ? state.inviterUID : state.peerUID
        audioStage.apply(uid: who, name: imResolvedName(controller.profileResolver, uid: who, fallback: who.isEmpty ? (peer?.uid ?? imT("call.ongoing")) : who),
                         status: imCallStatusLine(state), isRinging: state.phase == .outgoing,
                         networkLevel: peer?.networkLevel ?? 0,
                         // 接通之后名字与时长归标题栏，中间只留头像——两处各走各的计时是重复也是打架。
                         showsCaption: state.phase != .active,
                         avatarImage: imResolvedAvatar(controller.profileResolver, uid: who))
        gridView.layout([])
        fullStage.unpin()
        // 拨出视频时右上角叠本端预览（草图 §03-E：拨出时看得见自己）。
        let showPreview = state.mediaType == "video" && state.selfState.cameraOn && controller.hasLocalCamera
        applySelfTile(state, avatarSize: IMKitTheme.current.avatarSmall)
        pip.setContent(showPreview ? selfTile : nil)
        pip.isHidden = !showPreview
        pip.liftsForControls = false
        controller.attachLocalPreview(to: showPreview ? selfTile.renderView : nil)
        remoteTiles.retire(keeping: [])
    }

    private func renderVideo(_ state: IMCallViewState) {
        guard let peer = state.participants.first else { return }
        let remote = remoteTiles.tile(for: peer.uid)
        remoteTiles.retire(keeping: [peer.uid])
        gridView.layout([])
        // 默认远端全屏、本端小窗；互换后反过来。**层上界跟着换**：进小窗的报 l，上全屏的报 h。
        let (full, small): (IMVideoTileView, IMVideoTileView) = state.isSwapped ? (selfTile, remote) : (remote, selfTile)
        /*
         **1v1 不做发言高亮**（绿描边 + 绿名牌）：只有两个人，谁在说话本来就一目了然，
         而那圈绿边压在全屏画面上只会显得像出了什么问题。九宫格里才需要它。
        */
        remote.apply(uid: peer.uid,
                     label: imResolvedName(controller.profileResolver, uid: peer.uid, fallback: peer.uid),
                     hasVideo: peer.hasVideo, hasAudio: peer.hasAudio,
                     isSpeaking: false, networkLevel: peer.networkLevel,
                     avatarSize: state.isSwapped ? IMKitTheme.current.avatarSmall : IMKitTheme.current.avatarLarge,
                     avatarImage: imResolvedAvatar(controller.profileResolver, uid: peer.uid))
        applySelfTile(state, avatarSize: state.isSwapped ? IMKitTheme.current.avatarLarge : IMKitTheme.current.avatarSmall)
        fullStage.pin(full)
        pip.setContent(small)
        pip.isHidden = false
        pip.liftsForControls = chrome.visible
        pip.accessibilityLabel = state.isSwapped ? imT("pip.peerLabel") : imT("aria.selfView")
        controller.attachLocalPreview(to: selfTile.renderView)
        remoteTiles.report(peer.uid, layer: state.isSwapped ? "l" : "h", hasVideo: peer.hasVideo)
    }

    private func renderGrid(_ state: IMCallViewState) {
        fullStage.unpin()
        pip.setContent(nil)
        pip.isHidden = true
        // 会议房走分页画廊 / 演讲者视图（IMCallOverlayViewController+Meeting.swift）；
        // 群通话还是老的九宫格，一行都没变（设计 §3 的门控表）。
        if state.isMeeting {
            renderMeeting(state)
            return
        }
        gridView.fixedTileCount = nil
        gridView.pageText = ""
        let visible = imVisibleTiles(state.participants)
        remoteTiles.retire(keeping: Set(visible.map(\.uid)))
        var ordered: [UIView] = []
        applySelfTile(state, avatarSize: IMKitTheme.current.avatarSmall)
        controller.attachLocalPreview(to: state.mediaType == "video" ? selfTile.renderView : nil)
        ordered.append(selfTile)
        for p in visible {
            let tile = remoteTiles.tile(for: p.uid)
            tile.apply(uid: p.uid,
                       label: imResolvedName(controller.profileResolver, uid: p.uid, fallback: p.uid),
                       hasVideo: p.hasVideo, hasAudio: p.hasAudio, isSpeaking: p.isSpeaking, volume: p.volume,
                       isRinging: !p.hasAccepted, settled: p.settled, networkLevel: p.networkLevel,
                       avatarImage: imResolvedAvatar(controller.profileResolver, uid: p.uid))
            ordered.append(tile)
        }
        /*
         **九宫格里没有加号格**（v3.3 撤掉）。加人入口只有标题栏右上角那一颗
         （`imCanShowInvite` 同一条判据）：网格里再放一个是同一个动作的第二个入口，
         而它还会占掉一个格位——三个人的通话看起来像四个人，行列也跟着多排一格。
        */
        gridView.layout(ordered)
        // 层上界按真人的格子数算，加号格不算——它不收流。
        let layer = imTileLayer(visible.count + 1)
        // 没格子的人视频报 none、并说一句「还有 N 人未显示」（会议房 M1 止血，MEETING_ROOM_DESIGN §4.3 / §4.5）。
        for (i, p) in state.participants.enumerated() { remoteTiles.report(p.uid, layer: i < visible.count ? layer : "none", hasVideo: p.hasVideo) }
        gridView.hiddenCount = state.participants.count - visible.count
    }

    /// 本端那格。**只表达麦克风开 / 关两态**（2026-09-09 拍板）——自己在不在说话自己知道，
    /// 所以不再需要「哪种版式才显示说话」那个参数，三种版式一视同仁。
    func applySelfTile(_ state: IMCallViewState, avatarSize: CGFloat) {
        selfTile.apply(uid: "", label: imT("self"), hasVideo: state.selfState.cameraOn && controller.hasLocalCamera,
                       hasAudio: state.selfState.micOn,
                       isSpeaking: false, volume: 0, showsSpeaking: false,
                       avatarSize: avatarSize,
                       /*
                        **只有前置才镜像。**

                        原先写死 true，后置摄像头也跟着左右翻——举着手机拍白板，
                        自己看到的字是反的。镜像是「照镜子」那个习惯，只对着自己的脸才成立。
                        （Android 一直是 `renderer.setMirror(frontCamera)`，这次向它对齐。）
                       */
                       isMirrored: controller.isUsingFrontCamera)
    }

}

extension IMCallOverlayViewController: IMCallControllerObserver {
    public func callController(_ controller: IMCallController, didChange state: IMCallViewState) {
        render(state)
    }
}
#endif
