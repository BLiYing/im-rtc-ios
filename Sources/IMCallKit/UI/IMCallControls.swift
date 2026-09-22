#if canImport(UIKit)
import UIKit

/**
 通话页控制条（从 `IMCallOverlayViewController` 抽出的协作对象，CONVENTIONS §2）。

 控制条**两排**（v3.2）：上排三个开关（静音 / 摄像头 / 扬声器），
 下排「挂断居中 + 翻转摄像头在它右边」。

 下排用三格等宽：左边一格空着，挂断占中间那格所以**真的在屏幕正中**，翻转占右边那格。
 少了左边那个占位，挂断就会偏左——红键偏了最容易点错。

 只管「这一阶段摆哪几颗、每颗什么样」；按钮点了做什么由 VC 接（`addTarget`），这里不认 controller。
 */
final class IMCallControls {
    let stack = UIStackView()
    let micButton = IMControlButton(icon: .mic, caption: imT("ctl.mute"), onIcon: .micSlash, onCaption: imT("ctl.muted"))
    let cameraButton = IMControlButton(icon: .videoSlash, caption: imT("ctl.cameraOn"), onIcon: .video, onCaption: imT("ctl.cameraOff"))
    let speakerButton = IMControlButton(icon: .speaker, caption: imT("ctl.speaker"), onIcon: .speaker, onCaption: imT("ctl.speaker"))
    let switchCameraButton = IMControlButton(icon: .cameraFlip, caption: imT("ctl.flip"))
    let endButton = IMControlButton(role: .danger, icon: .phoneDown, caption: imT("ctl.hangup"))
    let acceptButton = IMControlButton(role: .accept, icon: .phone, caption: imT("ctl.accept"))
    let rejectButton = IMControlButton(role: .danger, icon: .xmark, caption: imT("ctl.reject"))

    private let top = UIStackView()
    private let bottom = UIStackView()
    /// 下排左边那个空位：有它挂断才真的在屏幕正中。
    private let spacer = UIView()

    init() {
        for row in [top, bottom] {
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = 12
        }
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.addArrangedSubview(top)
        stack.addArrangedSubview(bottom)
    }

    /// render 按阶段换按钮组。来电时是「拒绝 / 接听」，其余是常规几件套。**结束态不显示任何按钮。**
    func render(_ state: IMCallViewState) {
        micButton.isOn = !state.selfState.micOn
        cameraButton.isOn = state.selfState.cameraOn
        cameraButton.isDisabledLook = state.selfState.cameraBlocked
        cameraButton.caption = imT(state.selfState.cameraBlocked ? "ctl.cameraBlocked" : "ctl.cameraOn")
        renderSpeakerButton(state)

        let (topRow, bottomRow) = rows(for: state)
        fill(top, with: topRow)
        fill(bottom, with: bottomRow)
        // 摄像头关着的时候翻转没有意义（也没有画面可翻）。
        switchCameraButton.isEnabled = state.selfState.cameraOn && !state.selfState.cameraBlocked
        switchCameraButton.alpha = switchCameraButton.isEnabled ? 1 : 0.4
        // 红按钮的语义按房间类型分叉（规范 §05）：群 / 会议写「离开」，拨出中写「取消」。
        endButton.caption = imT(state.isGroup || state.isMeeting ? "ctl.leave" : state.phase == .outgoing ? "ctl.cancel" : "ctl.hangup")
    }

    /**
     扬声器键的两种形态（设计稿 §04 v3.5）。

     只有内置两条路由时是**二态开关**（今天的行为，点一下就切）；出现第三条路由时变成
     **路由选择**——图标换成当前路由的字形、文案换成设备名、右下角叠一枚 `chevron-up` 角标，
     点它升起 `IMAudioRoutePanel` 而不是直接切。**两种形态是同一颗按钮**，
     所以这里只换外观，不换视图（换视图会打断按下动效、也会让 `fillEqually` 抖一下）。
    */
    private func renderSpeakerButton(_ state: IMCallViewState) {
        let routes = state.selfState.audioRoutes
        guard imShowsRoutePicker(routes) else {
            speakerButton.showsRouteChevron = false
            speakerButton.overrideIcon = nil
            speakerButton.caption = imT("ctl.speaker")
            speakerButton.isOn = state.selfState.speakerOn
            return
        }
        // 路由选择形态：亮不亮已经没有意义（四选一不是开关），恒暗，靠图标与文案表达。
        speakerButton.isOn = false
        speakerButton.showsRouteChevron = true
        let current = state.selfState.currentAudioRoute
        speakerButton.overrideIcon = current.map { imRouteIcon($0.kind) } ?? .speaker
        speakerButton.caption = current.map(imRouteDisplayName) ?? imT("ctl.speaker")
    }

    private func rows(for state: IMCallViewState) -> ([UIView], [UIView]) {
        if state.phase == .ended { return ([], []) }
        if state.phase == .incoming {
            // 视频来电多一个摄像头开关，而不是「以语音接听」按钮（拍板 §11-10）。
            return ([], imShowsCameraButton(for: state) ? [cameraButton, rejectButton, acceptButton] : [rejectButton, acceptButton])
        }
        if imShowsCameraButton(for: state) {
            // 「小窗」不在控制条里——它在标题栏左上角那一颗（IMCallHeaderView 的注释）。
            return ([micButton, cameraButton, speakerButton], [spacer, endButton, switchCameraButton])
        }
        // 语音通话不给摄像头按钮，也就没有翻转（imShowsCameraButton）。
        return ([micButton, speakerButton], [endButton])
    }

    /// 摆一排按钮。内容没变就不重建（重建会打断按下动效）。
    private func fill(_ row: UIStackView, with wanted: [UIView]) {
        guard row.arrangedSubviews != wanted else { return }
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        wanted.forEach { row.addArrangedSubview($0) }
        row.isHidden = wanted.isEmpty
    }
}
#endif
