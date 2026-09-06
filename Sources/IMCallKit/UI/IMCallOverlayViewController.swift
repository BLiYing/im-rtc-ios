#if canImport(UIKit)
import UIKit
import IMCallEngine

/*
 通话主界面，三种版式（规范 §03 / §04）：
 · **audio**：语音通话、拨出中 —— 96 头像 + 名字 + 状态（拨出视频时右上叠本端预览）；
 · **video**：1v1 视频通话中 —— 远端全屏 + 本端小窗，单击小窗互换，控制条 3s 自动隐藏；
 · **grid**：群通话 / 会议 —— 九宫格 + 加号格（只有主叫可见）。

 **三种版式做在一个 VC 里而不是三个**：静音状态、发言高亮、计时这些在每一态都要维护，
 拆开就得维护三遍，而且态与态之间切换会闪一下。版式由 `imPickLayout` 决定（纯函数，有单测）。

 全屏深色，不随宿主主题（草图 §03）。头部 / 橙条 / 提示卡在 IMCallChromeViews.swift，
 小窗手势在 IMPipView.swift，语音页在 IMAudioStageView.swift。
 */
public final class IMCallOverlayViewController: UIViewController {

    private let controller: IMCallController
    private let gradient = CAGradientLayer()
    private let banner = IMTopBannerView()
    private let header = IMCallHeaderView()
    private let stage = UIView()
    private let audioStage = IMAudioStageView()
    private let gridView = IMCallGridView()
    private let pip = IMPipView()
    /// 结束画面那一句话。**结束态不复用通话页的骨架**——那会把接通后才有的按钮铺出来。
    private let endedLabel = UILabel()
    /// 本端格子。群通话里它是格子之一；1v1 里在小窗（互换后到全屏）。
    private let selfTile = IMVideoTileView()
    private let addTile = UIButton(type: .system)
    private let controlsScrim = CAGradientLayer()
    private let controlsStack = UIStackView()
    /// 复用格子，按 uid 索引。**不每次重建**：重建会让媒体层挂上去的渲染视图跟着重来，画面会闪。
    private var tiles: [String: IMVideoTileView] = [:]
    private var reportedLayers: [String: String] = [:]
    /// 当前把哪个格子钉成了全屏（视频版式）。
    private var fullTile: IMVideoTileView?
    private var fullConstraints: [NSLayoutConstraint] = []

    private let micButton = IMControlButton(icon: .mic, caption: "静音", onIcon: .micSlash, onCaption: "已静音")
    private let cameraButton = IMControlButton(icon: .videoSlash, caption: "开摄像头", onIcon: .video, onCaption: "关摄像头")
    private let speakerButton = IMControlButton(icon: .speaker, caption: "扬声器", onIcon: .speaker, onCaption: "扬声器")
    private let minimizeControl = IMControlButton(icon: .minimize, caption: "小窗")
    private let endButton = IMControlButton(role: .danger, icon: .phoneDown, caption: "挂断")
    private let acceptButton = IMControlButton(role: .accept, icon: .phone, caption: "接听")
    private let rejectButton = IMControlButton(role: .danger, icon: .xmark, caption: "拒绝")

    /// 计时器。**持有方释放时必须 cancel**（CONVENTIONS §5）。
    private var tickTimer: DispatchSourceTimer?
    private var autoHideTimer: DispatchSourceTimer?
    private var networkBannerTimer: DispatchSourceTimer?
    private var chromeVisible = true
    private var poorNetworkShown = false

    public init(controller: IMCallController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    deinit {
        tickTimer?.cancel()
        autoHideTimer?.cancel()
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
        controlsScrim.colors = [UIColor.clear.cgColor, UIColor(white: 0, alpha: 0.55).cgColor]
        controlsScrim.isHidden = true

        controlsStack.axis = .horizontal
        controlsStack.distribution = .fillEqually
        controlsStack.alignment = .top
        controlsStack.spacing = 12

        endedLabel.font = .systemFont(ofSize: 17)
        endedLabel.textColor = theme.primaryText
        endedLabel.textAlignment = .center
        endedLabel.numberOfLines = 0

        addTile.setImage(IMKitIcon.plus.image(pointSize: 22), for: .normal)
        addTile.tintColor = theme.primaryText
        addTile.alpha = 0.8
        addTile.layer.cornerRadius = theme.tileCornerRadius
        addTile.layer.borderWidth = 1.5
        addTile.layer.borderColor = UIColor(white: 1, alpha: 0.3).cgColor
        addTile.accessibilityLabel = "添加成员"
        addTile.addTarget(self, action: #selector(onInvite), for: .touchUpInside)

        for child in [header, stage, endedLabel, controlsStack, banner] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        view.layer.insertSublayer(controlsScrim, below: controlsStack.layer)
        for child in [audioStage, gridView, pip] as [UIView] {
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
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            banner.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            banner.centerXAnchor.constraint(equalTo: guide.centerXAnchor),

            stage.topAnchor.constraint(equalTo: header.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: controlsStack.topAnchor),
            endedLabel.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            endedLabel.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            endedLabel.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 24),
            endedLabel.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -24),

            controlsStack.heightAnchor.constraint(equalToConstant: theme.controlsHeight),
            controlsStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            controlsStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -26),
        ])
        pin(audioStage, to: stage)
        pin(gridView, to: stage, inset: 12)

        header.minimizeButton.addTarget(self, action: #selector(onMinimize), for: .touchUpInside)
        header.inviteButton.addTarget(self, action: #selector(onInvite), for: .touchUpInside)
        micButton.addTarget(self, action: #selector(onMic), for: .touchUpInside)
        cameraButton.addTarget(self, action: #selector(onCamera), for: .touchUpInside)
        minimizeControl.addTarget(self, action: #selector(onMinimize), for: .touchUpInside)
        endButton.addTarget(self, action: #selector(onEnd), for: .touchUpInside)
        acceptButton.addTarget(self, action: #selector(onAccept), for: .touchUpInside)
        rejectButton.addTarget(self, action: #selector(onReject), for: .touchUpInside)
        speakerButton.addTarget(self, action: #selector(onSpeaker), for: .touchUpInside)
        pip.onTap = { [weak self] in
            guard let self else { return }
            // 拨出中小窗里只有自己、对端还没画面，没什么可换。
            guard imPickLayout(for: self.controller.state, hasLocalVideo: self.controller.hasLocalCamera) == .video else { return }
            self.controller.setSwapped(!self.controller.state.isSwapped)
        }
        // 单击画面空白处：显示 / 隐藏控制条（视频版式才生效）。
        stage.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onStageTap)))
    }

    private func pin(_ child: UIView, to parent: UIView, inset: CGFloat = 0) {
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

    // MARK: - 动作

    @objc private func onMic() { controller.toggleMic() }
    @objc private func onCamera() { controller.toggleCamera() }
    @objc private func onMinimize() { controller.setMinimized(true) }
    @objc private func onEnd() { controller.end() }
    @objc private func onAccept() { controller.accept() }
    @objc private func onReject() { controller.reject() }
    @objc private func onSpeaker() { controller.toggleSpeaker() }
    @objc private func onInvite() {
        let picker = IMInvitePickerViewController(controller: controller)
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @objc private func onStageTap() {
        guard currentLayout == .video else { return }
        setChrome(visible: !chromeVisible)
    }

    // MARK: - 渲染

    private var currentLayout: IMCallLayout {
        imPickLayout(for: controller.state, hasLocalVideo: controller.hasLocalCamera)
    }

    /// startTicking 每秒刷一次时长。**只在通话中跑**，其余状态没有时长可显示。
    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.controller.state.phase == .active else { return }
            self.renderHeader(self.controller.state)
        }
        tickTimer = timer
        timer.resume()
    }

    private func render(_ state: IMCallViewState) {
        let layout = currentLayout
        let isEnded = state.phase == .ended
        renderHeader(state)
        endedLabel.isHidden = !isEnded
        endedLabel.text = statusLine(state)
        gradient.isHidden = layout == .video && !isEnded
        controlsScrim.isHidden = layout != .video || isEnded
        audioStage.isHidden = layout != .audio || isEnded
        gridView.isHidden = layout != .grid || isEnded
        pip.isHidden = isEnded
        micButton.isOn = !state.selfState.micOn
        cameraButton.isOn = state.selfState.cameraOn
        cameraButton.isDisabledLook = state.selfState.cameraBlocked
        cameraButton.caption = state.selfState.cameraBlocked ? "无权限" : "开摄像头"
        speakerButton.isOn = state.selfState.speakerOn
        renderControls(state)
        renderBanner(state)
        if isEnded {
            controller.attachLocalPreview(to: nil)
            return
        }
        switch layout {
        case .audio: renderAudio(state)
        case .video: renderVideo(state)
        case .grid: renderGrid(state)
        }
        // 视频版式外 chrome 永远可见；进视频版式时重新计时。
        if layout != .video { setChrome(visible: true, arm: false) } else if chromeVisible { armAutoHide() }
    }

    private func renderHeader(_ state: IMCallViewState) {
        let peerLevel = state.isGroup ? 0 : (state.participants.first?.networkLevel ?? 0)
        header.apply(title: title(state), subtitle: statusLine(state),
                     networkLevel: state.phase == .active ? peerLevel : 0,
                     showsMinimize: state.phase != .incoming && state.phase != .ended,
                     showsInvite: imCanShowInvite(for: state))
    }

    /// 顶部橙条：正在重连 / 连接已断开 / 对方网络不佳（2s 后收成角标，**不一直霸占顶部**）。
    private func renderBanner(_ state: IMCallViewState) {
        switch state.connection {
        case .reconnecting: banner.apply(text: "正在重连…"); return
        case .lost: banner.apply(text: "连接已断开"); return
        case .ok: break
        }
        let poor = state.participants.contains { imIsNetworkPoor(level: $0.networkLevel) }
        if poor, !poorNetworkShown {
            poorNetworkShown = true
            banner.apply(text: "对方网络不佳")
            networkBannerTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + IMKitTheme.current.networkBannerHold)
            timer.setEventHandler { [weak self] in self?.banner.apply(text: "") }
            networkBannerTimer = timer
            timer.resume()
        } else if !poor {
            poorNetworkShown = false
            banner.apply(text: "")
        }
    }

    /// renderControls 按阶段换按钮组。来电时是「拒绝 / 接听」，其余是常规几件套。**结束态不显示任何按钮。**
    private func renderControls(_ state: IMCallViewState) {
        let wanted: [UIView]
        if state.phase == .ended {
            wanted = []
        } else if state.phase == .incoming {
            // 视频来电多一个摄像头开关，而不是「以语音接听」按钮（拍板 §11-10）。
            wanted = imShowsCameraButton(for: state) ? [cameraButton, rejectButton, acceptButton] : [rejectButton, acceptButton]
        } else {
            // 语音通话不给摄像头按钮（imShowsCameraButton）。
            wanted = imShowsCameraButton(for: state)
                ? [micButton, cameraButton, speakerButton, minimizeControl, endButton]
                : [micButton, speakerButton, minimizeControl, endButton]
        }
        if controlsStack.arrangedSubviews != wanted {
            controlsStack.arrangedSubviews.forEach { controlsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            wanted.forEach { controlsStack.addArrangedSubview($0) }
        }
        // 红按钮的语义按房间类型分叉（规范 §05）：群 / 会议写「离开」，拨出中写「取消」。
        endButton.caption = state.isGroup || state.isMeeting ? "离开" : state.phase == .outgoing ? "取消" : "挂断"
    }

    // MARK: 三种版式

    private func renderAudio(_ state: IMCallViewState) {
        let peer = state.participants.first
        audioStage.apply(uid: state.peerUID, name: state.peerUID.isEmpty ? (peer?.uid ?? "通话中") : state.peerUID,
                         status: statusLine(state), isRinging: state.phase == .outgoing,
                         networkLevel: peer?.networkLevel ?? 0)
        gridView.layout([])
        unpinFull()
        // 拨出视频时右上角叠本端预览（草图 §03-E：拨出时看得见自己）。
        let showPreview = state.mediaType == "video" && state.selfState.cameraOn && controller.hasLocalCamera
        applySelfTile(state, avatarSize: 44)
        pip.setContent(showPreview ? selfTile : nil)
        pip.isHidden = !showPreview
        pip.liftsForControls = false
        controller.attachLocalPreview(to: showPreview ? selfTile.renderView : nil)
        retireTiles(keeping: [])
    }

    private func renderVideo(_ state: IMCallViewState) {
        guard let peer = state.participants.first else { return }
        let remote = tiles[peer.uid] ?? makeTile(for: peer.uid)
        retireTiles(keeping: [peer.uid])
        gridView.layout([])
        // 默认远端全屏、本端小窗；互换后反过来。**层上界跟着换**：进小窗的报 l，上全屏的报 h。
        let (full, small): (IMVideoTileView, IMVideoTileView) = state.isSwapped ? (selfTile, remote) : (remote, selfTile)
        remote.apply(uid: peer.uid, label: peer.uid, hasVideo: peer.hasVideo, hasAudio: peer.hasAudio,
                     isSpeaking: peer.isSpeaking, networkLevel: peer.networkLevel,
                     avatarSize: state.isSwapped ? 44 : IMKitTheme.current.avatarLarge)
        applySelfTile(state, avatarSize: state.isSwapped ? IMKitTheme.current.avatarLarge : 44)
        pinFull(full)
        pip.setContent(small)
        pip.isHidden = false
        pip.liftsForControls = chromeVisible
        pip.accessibilityLabel = state.isSwapped ? "对方画面" : "本端画面"
        controller.attachLocalPreview(to: selfTile.renderView)
        report(peer.uid, layer: state.isSwapped ? "l" : "h")
    }

    private func renderGrid(_ state: IMCallViewState) {
        unpinFull()
        pip.setContent(nil)
        pip.isHidden = true
        let visible = imVisibleTiles(state.participants)
        retireTiles(keeping: Set(visible.map(\.uid)))
        var ordered: [UIView] = []
        applySelfTile(state, avatarSize: 44)
        controller.attachLocalPreview(to: state.mediaType == "video" ? selfTile.renderView : nil)
        ordered.append(selfTile)
        for p in visible {
            let tile = tiles[p.uid] ?? makeTile(for: p.uid)
            tile.apply(uid: p.uid, label: p.uid, hasVideo: p.hasVideo, hasAudio: p.hasAudio, isSpeaking: p.isSpeaking,
                       isRinging: !p.hasAccepted, settled: p.settled, networkLevel: p.networkLevel)
            ordered.append(tile)
        }
        // 加人入口放在网格里（交互稿 §05）：它天然占着「下一个人的位置」。只有主叫、没满员时才有。
        if imCanShowInvite(for: state) { ordered.append(addTile) }
        gridView.layout(ordered)
        // 层上界按真人的格子数算，加号格不算——它不收流。
        let layer = imTileLayer(visible.count + 1)
        for p in visible { report(p.uid, layer: layer) }
    }

    private func applySelfTile(_ state: IMCallViewState, avatarSize: CGFloat) {
        selfTile.apply(uid: "", label: "我", hasVideo: state.selfState.cameraOn && controller.hasLocalCamera,
                       hasAudio: state.selfState.micOn, isSpeaking: false, avatarSize: avatarSize, isMirrored: true)
    }

    private func pinFull(_ tile: IMVideoTileView) {
        guard fullTile !== tile else { return }
        unpinFull()
        tile.layer.cornerRadius = 0
        tile.translatesAutoresizingMaskIntoConstraints = false
        stage.insertSubview(tile, at: 0)
        fullConstraints = [
            tile.topAnchor.constraint(equalTo: stage.topAnchor), tile.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: stage.trailingAnchor), tile.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ]
        NSLayoutConstraint.activate(fullConstraints)
        fullTile = tile
    }

    private func unpinFull() {
        NSLayoutConstraint.deactivate(fullConstraints)
        fullConstraints = []
        if let fullTile, fullTile.superview === stage { fullTile.removeFromSuperview() }
        fullTile?.layer.cornerRadius = IMKitTheme.current.tileCornerRadius
        fullTile = nil
    }

    /// retireTiles 收掉不再需要的远端格子。卸载要成对：不摘的话解码器还占着（CONVENTIONS §7）。
    private func retireTiles(keeping wanted: Set<String>) {
        for (uid, tile) in tiles where !wanted.contains(uid) {
            controller.attachView(uid, to: nil)
            tile.removeFromSuperview()
            tiles[uid] = nil
            reportedLayers[uid] = nil
        }
    }

    private func makeTile(for uid: String) -> IMVideoTileView {
        let tile = IMVideoTileView()
        tiles[uid] = tile
        controller.attachView(uid, to: tile.renderView)
        return tile
    }

    /// 格子大小变了就重报层上界，同一个值不重复发。**这是省带宽的关键一步**。
    private func report(_ uid: String, layer: String) {
        guard reportedLayers[uid] != layer else { return }
        reportedLayers[uid] = layer
        controller.reportLayer(uid, layer)
    }

    // MARK: 控制条自动隐藏（规范 §07：3s 后淡出，任意触摸恢复）

    private func setChrome(visible: Bool, arm: Bool = true) {
        chromeVisible = visible
        UIView.animate(withDuration: IMKitTheme.current.fadeDuration) {
            self.header.alpha = visible ? 1 : 0
            self.controlsStack.alpha = visible ? 1 : 0
            self.controlsScrim.opacity = visible ? 1 : 0
        }
        controlsStack.isUserInteractionEnabled = visible
        header.isUserInteractionEnabled = visible
        pip.liftsForControls = visible && currentLayout == .video
        if visible, arm { armAutoHide() } else { autoHideTimer?.cancel() }
    }

    private func armAutoHide() {
        autoHideTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + IMKitTheme.current.autoHideDelay)
        timer.setEventHandler { [weak self] in
            guard let self, self.currentLayout == .video, self.controller.state.phase == .active else { return }
            self.setChrome(visible: false)
        }
        autoHideTimer = timer
        timer.resume()
    }

    // MARK: 文案

    private func title(_ state: IMCallViewState) -> String {
        if state.isMeeting { return "会议 · \(state.participants.count + 1) 人" }
        if state.isGroup { return "群通话 · \(state.participants.count + 1) 人" }
        return state.peerUID.isEmpty ? "通话" : state.peerUID
    }

    private func statusLine(_ state: IMCallViewState) -> String {
        if !state.hint.isEmpty { return state.hint }
        switch state.phase {
        case .incoming:   return state.mediaType == "video" ? "邀请你视频通话" : "邀请你语音通话"
        case .outgoing:   return "正在呼叫…"
        case .connecting: return state.isMeeting ? "正在进入会议…" : "接通中…"
        case .ended:
            return state.isMeeting ? "已离开会议"
                : imEndReasonText(state.endReason, role: state.role,
                                  durationSec: Int(Date().timeIntervalSince1970 - state.beganAt))
        case .active:     return imFormatDuration(Int(Date().timeIntervalSince1970 - state.beganAt))
        case .idle:       return ""
        }
    }
}

extension IMCallOverlayViewController: IMCallControllerObserver {
    public func callController(_ controller: IMCallController, didChange state: IMCallViewState) {
        render(state)
    }
}
#endif
