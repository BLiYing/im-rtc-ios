#if canImport(UIKit)
import UIKit

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
    private let gridView = UIView()
    private let controlsStack = UIStackView()

    /// 复用格子，按 uid 索引。**不每次重建**：重建会让媒体层挂上去的渲染视图跟着重来，
    /// 画面会闪。
    private var tiles: [String: IMVideoTileView] = [:]

    private let micButton = IMControlButton(icon: "🎤", caption: "静音",
                                            onIcon: "🔇", onCaption: "已静音")
    private let cameraButton = IMControlButton(icon: "📷", caption: "开摄像头",
                                               onIcon: "📹", onCaption: "关摄像头")
    private let minimizeControl = IMControlButton(icon: "⌄", caption: "小窗")
    private let endButton = IMControlButton(role: .danger, icon: "📵", caption: "挂断")
    private let acceptButton = IMControlButton(role: .accept, icon: "📹", caption: "接听")
    private let rejectButton = IMControlButton(role: .danger, icon: "✕", caption: "拒绝")
    /// 视频来电才有：接了但本端不开摄像头（草图 §03-F）。
    private let audioAcceptButton = IMControlButton(icon: "🎤", caption: "以语音接听")
    private let speakerButton = IMControlButton(icon: "🔈", caption: "扬声器",
                                                onIcon: "🔊", onCaption: "扬声器")
    private let networkBars = IMNetworkBars()

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
        controlsStack.distribution = .equalSpacing
        controlsStack.alignment = .top
        controlsStack.spacing = 12

        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, networkBars])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 2

        for view in [minimizeButton, header, gridView, controlsStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(view)
        }

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            minimizeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            minimizeButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            minimizeButton.widthAnchor.constraint(equalToConstant: 32),

            header.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            header.centerXAnchor.constraint(equalTo: guide.centerXAnchor),

            gridView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            gridView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            gridView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            gridView.bottomAnchor.constraint(equalTo: controlsStack.topAnchor, constant: -16),

            controlsStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            controlsStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            controlsStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24),
        ])

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
        titleLabel.text = title(state)
        subtitleLabel.text = statusLine(state)
        minimizeButton.isHidden = state.phase == .incoming || state.phase == .ended
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
        if state.phase == .incoming {
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

    /// renderTiles 摆格子。**复用已有的格子**，只有名单变了才增删。
    private func renderTiles(_ state: IMCallViewState) {
        let visible = imVisibleTiles(state.participants)
        let wantedUIDs = Set(visible.map(\.uid))

        for (uid, tile) in tiles where !wantedUIDs.contains(uid) {
            tile.removeFromSuperview()
            tiles[uid] = nil
        }
        for participant in visible {
            let tile = tiles[participant.uid] ?? makeTile(for: participant.uid)
            tile.apply(uid: participant.uid,
                       label: participant.hasAccepted
                           ? participant.uid : "\(participant.uid)（响铃中）",
                       hasVideo: participant.hasVideo,
                       hasAudio: participant.hasAudio,
                       isSpeaking: participant.isSpeaking)
        }
        layoutTiles(visible.map(\.uid))
    }

    private func makeTile(for uid: String) -> IMVideoTileView {
        let tile = IMVideoTileView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        gridView.addSubview(tile)
        tiles[uid] = tile
        return tile
    }

    /// layoutTiles 按行列摆格子，并**把每个格子该报的层上界告诉 Engine**。
    ///
    /// 这是省带宽的关键一步：九宫格里每个人都按 h 层收，一屏就是 8 路 720p。
    private func layoutTiles(_ uids: [String]) {
        gridView.constraints.forEach { gridView.removeConstraint($0) }
        let dims = imGridDimensions(uids.count)
        let gap = IMKitTheme.current.tileGap

        for (index, uid) in uids.enumerated() {
            guard let tile = tiles[uid] else { continue }
            let row = index / dims.columns, column = index % dims.columns
            let width = 1.0 / CGFloat(dims.columns), height = 1.0 / CGFloat(dims.rows)
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(equalTo: gridView.widthAnchor,
                                            multiplier: width, constant: -gap),
                tile.heightAnchor.constraint(equalTo: gridView.heightAnchor,
                                             multiplier: height, constant: -gap),
                tile.leadingAnchor.constraint(
                    equalTo: gridView.leadingAnchor,
                    constant: CGFloat(column) * gap + gridView.bounds.width * width * CGFloat(column)),
                tile.topAnchor.constraint(
                    equalTo: gridView.topAnchor,
                    constant: CGFloat(row) * gap + gridView.bounds.height * height * CGFloat(row)),
            ])
        }
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
        case .ended:      return state.isMeeting ? "已离开会议" : "通话结束"
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
