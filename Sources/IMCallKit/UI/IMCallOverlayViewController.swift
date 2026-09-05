#if canImport(UIKit)
import UIKit
import IMCallEngine

/*
 通话主界面。草图 §03 的四态一屏一个：拨出中 / 来电 / 通话中 / 群通话九宫格。

 **四态做在一个 VC 里而不是四个**：静音状态、发言高亮、计时这些在每一态都要维护，
 拆成四个 VC 就得维护四遍，而且态与态之间切换会闪一下（要么转场、要么重建视图）。

 全屏深色，不随宿主主题（草图 §03）。
 */
public final class IMCallOverlayViewController: UIViewController {

    private let controller: IMCallController
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let minimizeButton = UIButton(type: .system)
    private let gridView = IMCallGridView()
    /**
     结束画面那一句话。**结束态不复用通话页的骨架**。

     原先结束态只是「把控制按钮清空」，标题、九宫格、本端预览还都在——
     被叫那边看上去就是「来电页忽然变成了通话页」，停一两秒再消失。
     实测反馈：「为何还弹出一个那个接通才有的界面」。
     现在结束态只留这一句居中的话（还在响铃的来电则根本不进结束态，直接收起）。
    */
    private let endedLabel = UILabel()
    /// 本端预览格子。群通话里它是格子之一；1v1 里浮在右上角。
    private let selfTile = IMVideoTileView()
    private let controlsStack = UIStackView()

    /// 复用格子，按 uid 索引。**不每次重建**：重建会让媒体层挂上去的渲染视图跟着重来，
    /// 画面会闪。
    private var tiles: [String: IMVideoTileView] = [:]
    /// 已经报过的层上界，避免每次刷新都往服务端发一遍 update_layer。
    private var reportedLayers: [String: String] = [:]

    private let micButton = IMControlButton(symbol: "mic.fill", caption: "静音",
                                            onSymbol: "mic.slash.fill", onCaption: "已静音")
    private let cameraButton = IMControlButton(symbol: "video.slash.fill", caption: "开摄像头",
                                               onSymbol: "video.fill", onCaption: "关摄像头")
    private let minimizeControl = IMControlButton(
        symbol: "arrow.down.right.and.arrow.up.left", caption: "小窗")
    private let endButton = IMControlButton(role: .danger, symbol: "phone.down.fill",
                                            caption: "挂断")
    private let acceptButton = IMControlButton(role: .accept, symbol: "phone.fill",
                                               caption: "接听")
    private let rejectButton = IMControlButton(role: .danger, symbol: "xmark", caption: "拒绝")
    /// 视频来电才有：接了但本端不开摄像头（草图 §03-F）。
    private let audioAcceptButton = IMControlButton(symbol: "phone.fill", caption: "以语音接听")
    private let speakerButton = IMControlButton(symbol: "speaker.fill", caption: "扬声器",
                                                onSymbol: "speaker.wave.2.fill",
                                                onCaption: "扬声器")
    private let networkBars = IMNetworkBars()

    /// 1v1 时把本端固定在右上角的那组约束；群通话时关掉，让它回到网格里。
    private var selfPreviewConstraints: [NSLayoutConstraint] = []
    /// 计时器。**持有方释放时必须 cancel**（CONVENTIONS §5）。
    private var tickTimer: DispatchSourceTimer?

    public init(controller: IMCallController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Kit 不用 storyboard") }

    deinit { tickTimer?.cancel() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        build()
        controller.addObserver(self)
        render(controller.state)
        startTicking()
    }

    /// 通话页固定深色，状态栏也要跟着变白（草图 §03）。
    public override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - 搭界面

    private func build() {
        let theme = IMKitTheme.current
        view.backgroundColor = theme.overlayBackground

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = theme.primaryText
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = theme.secondaryText

        minimizeButton.setTitle("⌄", for: .normal)
        minimizeButton.titleLabel?.font = .systemFont(ofSize: 22)
        minimizeButton.tintColor = theme.primaryText
        minimizeButton.accessibilityLabel = "收进小窗"
        minimizeButton.addTarget(self, action: #selector(onMinimize), for: .touchUpInside)

        controlsStack.axis = .horizontal
        controlsStack.distribution = .fillEqually
        controlsStack.alignment = .top
        controlsStack.spacing = 12

        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, networkBars])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 2

        /*
         **三段显式约束**：标题贴顶、控制条贴底、网格吃掉中间全部空间。

         中间试过用一根竖直 UIStackView + hugging 优先级来分配空间，**那是错的**：
         `UIStackView` 没有固有尺寸，`setContentHuggingPriority` 对它根本不起作用，
         于是三个子视图各自按自己的贴合尺寸排在顶上，剩余空间没人认领——
         实测就是「内容缩在顶部一条细带、下面空一大片」。

         显式约束把网格的高度**完全确定**下来（上顶标题、下顶控制条），
         不依赖任何优先级博弈。前提是网格内部那两条竖直边不能是 required
         （见 IMCallGridView），否则它的固有高度会反过来把这条链顶开。
        */
        endedLabel.font = .systemFont(ofSize: 17)
        endedLabel.textColor = theme.primaryText
        endedLabel.textAlignment = .center
        endedLabel.numberOfLines = 0

        for child in [minimizeButton, header, gridView, endedLabel, controlsStack] as [UIView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            minimizeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            minimizeButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            minimizeButton.widthAnchor.constraint(equalToConstant: 32),

            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            header.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            /*
             标题区同样要钉高度，理由和控制条一模一样：它也是个 UIStackView，
             也没有固有尺寸。只钉控制条的话，欠定就从控制条挪到了标题区——
             实测就是标题跑到屏幕正中间去了。
             64 = 标题 20 + 副标题 17 + 网络条 16 + 间距，够放且留一点余量。
            */
            header.heightAnchor.constraint(equalToConstant: 64),

            gridView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            gridView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            gridView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            gridView.bottomAnchor.constraint(equalTo: controlsStack.topAnchor, constant: -16),

            // 结束语占网格那块地方，居中。它和网格互斥显示。
            endedLabel.centerXAnchor.constraint(equalTo: gridView.centerXAnchor),
            endedLabel.centerYAnchor.constraint(equalTo: gridView.centerYAnchor),
            endedLabel.leadingAnchor.constraint(equalTo: gridView.leadingAnchor, constant: 24),
            endedLabel.trailingAnchor.constraint(equalTo: gridView.trailingAnchor, constant: -24),

            /*
             **控制条必须给一个显式高度。**

             `header → grid → controls → 安全区底` 这条链里有**两个未知高度**
             却只有一个等式——是欠定的。而 `UIStackView` 没有固有尺寸，
             `setContentHuggingPriority` 对它不起作用，所以没有任何东西阻止它
             把剩余空间全吃掉。实测（给三段上色看出来的）：控制条占满了下面三分之二，
             网格被挤成一条细带。

             把控制条钉死之后，网格的高度就被这条链完全确定了。
             56（圆）+ 6（间距）+ 文案一行。
            */
            controlsStack.heightAnchor.constraint(equalToConstant: theme.controlSize + 26),

            controlsStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            controlsStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            controlsStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
        ])

        // 1v1 时本端浮在右上角；群通话里它进网格（约束在 renderTiles 里开关）。
        selfTile.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(selfTile)
        selfPreviewConstraints = [
            selfTile.topAnchor.constraint(equalTo: gridView.topAnchor, constant: 12),
            selfTile.trailingAnchor.constraint(equalTo: gridView.trailingAnchor, constant: -12),
            selfTile.widthAnchor.constraint(equalToConstant: 96),
            selfTile.heightAnchor.constraint(equalToConstant: 128),
        ]

        micButton.addTarget(self, action: #selector(onMic), for: .touchUpInside)
        cameraButton.addTarget(self, action: #selector(onCamera), for: .touchUpInside)
        minimizeControl.addTarget(self, action: #selector(onMinimize), for: .touchUpInside)
        endButton.addTarget(self, action: #selector(onEnd), for: .touchUpInside)
        acceptButton.addTarget(self, action: #selector(onAccept), for: .touchUpInside)
        rejectButton.addTarget(self, action: #selector(onReject), for: .touchUpInside)
        audioAcceptButton.addTarget(self, action: #selector(onAudioAccept), for: .touchUpInside)
        speakerButton.addTarget(self, action: #selector(onSpeaker), for: .touchUpInside)
    }

    // MARK: - 动作

    @objc private func onMic() { controller.toggleMic() }
    @objc private func onCamera() { controller.toggleCamera() }
    @objc private func onMinimize() { controller.setMinimized(true) }
    @objc private func onEnd() { controller.end() }
    @objc private func onAccept() { controller.accept() }
    @objc private func onReject() { controller.reject() }
    @objc private func onAudioAccept() { controller.acceptAudioOnly() }
    @objc private func onSpeaker() { controller.toggleSpeaker() }

    // MARK: - 渲染

    /// startTicking 每秒刷一次时长。**只在通话中跑**，其余状态没有时长可显示。
    private func startTicking() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.controller.state.phase == .active else { return }
            self.subtitleLabel.text = self.statusLine(self.controller.state)
        }
        tickTimer = timer
        timer.resume()
    }

    private func render(_ state: IMCallViewState) {
        let isEnded = state.phase == .ended
        titleLabel.text = title(state)
        subtitleLabel.text = statusLine(state)
        // 结束态只留居中那一句，不再显示通话页的骨架（标题下的副标题会重复同一句话）。
        subtitleLabel.isHidden = isEnded
        gridView.isHidden = isEnded
        endedLabel.isHidden = !isEnded
        endedLabel.text = statusLine(state)
        minimizeButton.isHidden = state.phase == .incoming || isEnded
        micButton.isOn = !state.selfState.micOn
        cameraButton.isOn = state.selfState.cameraOn
        speakerButton.isOn = state.selfState.speakerOn
        // 1v1 显示对端的网络；群里每个格子各自的等级以后放格子上，这里只看整体。
        let level = state.participants.first?.networkLevel ?? 0
        networkBars.apply(level: state.phase == .active ? level : 0)
        renderControls(state)
        renderTiles(state)
    }

    /// renderControls 按阶段换按钮组。来电时是「拒绝 / 接听」，其余是常规四件套。
    private func renderControls(_ state: IMCallViewState) {
        let wanted: [UIView]
        /*
         **结束态不显示任何控制按钮。**

         实测反馈：对端挂断之后，本端反而弹出了「扬声器 / 关摄像头」这些
         接通后才该有的按钮——因为原先只把 `.incoming` 分了出去，
         剩下的（含 `.ended`）一律走通话中那一组。
         结束画面只需要说清为什么，停一两秒就收走。
        */
        if state.phase == .ended {
            wanted = []
        } else if state.phase == .incoming {
            wanted = state.mediaType == "video"
                ? [audioAcceptButton, rejectButton, acceptButton]
                : [rejectButton, acceptButton]
        } else {
            wanted = [micButton, cameraButton, speakerButton, minimizeControl, endButton]
        }
        guard controlsStack.arrangedSubviews != wanted else { return }
        controlsStack.arrangedSubviews.forEach {
            controlsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        wanted.forEach { controlsStack.addArrangedSubview($0) }
        // 会议里红按钮是「离开」不是「挂断」——会议房里根本没有 call。
        endButton.accessibilityLabel = state.isMeeting ? "离开会议" : "挂断"
    }

    /// renderTiles 摆格子，**并把画面挂上去**。
    ///
    /// 挂画面这一步一开始整条漏了：格子画好了、媒体也协商通了，但没人调
    /// `attachView`，于是画面永远不出现，而且不报任何错。
    private func renderTiles(_ state: IMCallViewState) {
        let visible = imVisibleTiles(state.participants)
        let wantedUIDs = Set(visible.map(\.uid))

        for (uid, tile) in tiles where !wantedUIDs.contains(uid) {
            // 卸载要成对：不摘的话解码器还占着（CONVENTIONS §7）。
            controller.attachView(uid, to: nil)
            tile.removeFromSuperview()
            tiles[uid] = nil
            reportedLayers[uid] = nil
        }

        var ordered: [IMVideoTileView] = []
        for participant in visible {
            let tile = tiles[participant.uid] ?? makeTile(for: participant.uid)
            tile.apply(uid: participant.uid,
                       label: participant.hasAccepted
                           ? participant.uid : "\(participant.uid)（响铃中）",
                       hasVideo: participant.hasVideo,
                       hasAudio: participant.hasAudio,
                       isSpeaking: participant.isSpeaking)
            ordered.append(tile)
        }

        // 群通话/会议里本端占一格；1v1 里本端是右上角的小画面（草图 §03-H）。
        let selfInGrid = state.isGroup || state.isMeeting
        selfTile.apply(uid: "", label: "我",
                       hasVideo: state.selfState.cameraOn && controller.hasLocalCamera,
                       hasAudio: state.selfState.micOn, isSpeaking: false)
        // 结束态那一屏不显示本端画面，**卸载要成对**：不摘的话摄像头的渲染器
        // 还挂在一个已经隐藏的视图上，解码/渲染照跑（CONVENTIONS §7）。
        let wantsSelfPreview = state.phase != .ended && state.mediaType == "video"
        controller.attachLocalPreview(to: wantsSelfPreview ? selfTile.renderView : nil)
        /*
         **拨出时就要能看见自己**（草图 §03-E：视频通话拨出中带本端画面）。

         为此 Kit 在 `callPlaced` 之后就起本端采集（见 IMCallController.placeCall），
         而不是等 `callBegin` 才推流——推流要先进房，而拨出中还没有房间。
         采集与发布是两件事，这一条正是它们要分开的原因。

         结束态不显示：那一屏只说结果。
        */
        let showSelf = wantsSelfPreview
        selfTile.isHidden = !showSelf
        if selfInGrid && showSelf { ordered.append(selfTile) }
        selfPreviewConstraints.forEach { $0.isActive = !selfInGrid && showSelf }

        gridView.layout(ordered)

        // 格子大小变了就重报层上界。**这是省带宽的关键一步**：
        // 九宫格里每个人都按 h 层收，一屏就是 8 路 720p。
        let layer = imTileLayer(ordered.count)
        for participant in visible where reportedLayers[participant.uid] != layer {
            reportedLayers[participant.uid] = layer
            controller.reportLayer(participant.uid, layer)
        }
    }

    private func makeTile(for uid: String) -> IMVideoTileView {
        let tile = IMVideoTileView()
        tiles[uid] = tile
        controller.attachView(uid, to: tile.renderView)
        return tile
    }

    private func title(_ state: IMCallViewState) -> String {
        if state.isMeeting { return "会议（\(state.participants.count + 1) 人）" }
        if state.isGroup { return "群通话（\(state.participants.count + 1) 人）" }
        return state.peerUID.isEmpty ? "通话" : state.peerUID
    }

    private func statusLine(_ state: IMCallViewState) -> String {
        if !state.hint.isEmpty { return state.hint }
        switch state.phase {
        case .incoming:
            return state.mediaType == "video" ? "邀请你视频通话" : "邀请你语音通话"
        case .outgoing:   return "正在呼叫…"
        case .connecting: return state.isMeeting ? "正在进入会议…" : "接通中…"
        case .ended:
            // **必须说清为什么**：只写「通话结束」然后消失，用户不知道是拒接、
            // 忙线还是对方压根不在线。
            return state.isMeeting ? "已离开会议"
                : imEndReasonText(state.endReason, role: state.role,
                                  durationSec: Int(Date().timeIntervalSince1970 - state.beganAt))
        case .active:
            let elapsed = Int(Date().timeIntervalSince1970 - state.beganAt)
            return imFormatDuration(elapsed)
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
